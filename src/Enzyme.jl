module Enzyme

export autodiff
export Const, Active, Duplicated

using LLVM
using LLVM.Interop
using Libdl
using Cassette

include("utils.jl")
include("compiler.jl")

abstract type Annotation{T} end 
struct Const{T} <: Annotation{T}
    val::T
end
struct Active{T<:AbstractFloat} <: Annotation{T}
    val::T
end
Active(i::Integer) = Active(float(i))
struct Duplicated{T} <: Annotation{T}
    val::T
    dval::T
end
struct DuplicatedNoNeed{T} <: Annotation{T}
    val::T
    dval::T
end

Base.eltype(::Type{<:Annotation{T}}) where T = T

struct LLVMThunk{RT}
    mod::LLVM.Module
    entry::LLVM.Function

    function LLVMThunk(f, tt; optimize=true, run_enzyme=true)
        primal_tt = map(eltype, tt) 

        # CTX, f are ghosts
        overdub_tt = Tuple{typeof(Compiler.CTX), typeof(f), primal_tt...}
        rt = Core.Compiler.return_type(Cassette.overdub, overdub_tt)
        # can't return array since that's complicated.
        @assert rt<:Union{AbstractFloat, Nothing}

        name   = String(nameof(f))
        source = Compiler.FunctionSpec(Cassette.overdub, overdub_tt, #=kernel=# false, #=name=# name)
        target = Compiler.EnzymeTarget()
        params = Compiler.EnzymeCompilerParams()
        job    = Compiler.CompilerJob(target, source, params)

        # Codegen the primal function and all its dependency in one module
        mod, primalf = Compiler.codegen(:llvm, job, optimize=false, validate=false)

        # Do our own validation 
        Compiler.check_ir(job, mod)        

        # Now build the actual wrapper function
        ctx     = context(mod)
        rettype = convert(LLVMType, rt)

        params = parameters(primalf)
        adjoint_tt = LLVMType[]
        for (i, T) in enumerate(tt)
            llvmT = llvmtype(params[i])
            push!(adjoint_tt, llvmT)
            if T <: Duplicated 
                push!(adjoint_tt, llvmT)
            end
        end

        # create a wrapper Function that we will inline into the llvmcall
        # generated by `call_function` in `autodiff`
        llvmf = LLVM.Function(mod, "enzyme_entry", LLVM.FunctionType(rettype, adjoint_tt))
        push!(function_attributes(llvmf), EnumAttribute("alwaysinline", 0, ctx))

        # Create the FunctionType and funtion decleration for the intrinsic
        pt       = LLVM.PointerType(LLVM.Int8Type(ctx))
        ftd      = LLVM.FunctionType(rettype, LLVMType[pt], true)
        autodiff = LLVM.Function(mod, string("__enzyme_autodiff.", rt), ftd)

        params = LLVM.Value[]
        llvm_params = parameters(llvmf)
        i = 1
        for T in tt
            if T <: Const
                push!(params, MDString("diffe_const"))
            elseif T <: Active
                push!(params, MDString("diffe_out"))
            elseif T <: Duplicated
                push!(params, MDString("diffe_dup"))
                push!(params, llvm_params[i])
                i += 1
            elseif T <: DuplicatedNoNeed
                push!(params, MDString("diffe_dupnoneed"))
                push!(params, llvm_params[i])
                i += 1
            else
                @assert("illegal annotation type")
            end
            push!(params, llvm_params[i])
            i += 1
        end

        Builder(ctx) do builder
            entry = BasicBlock(llvmf, "entry", ctx)
            position!(builder, entry)

            tc = bitcast!(builder, primalf,  pt)
            pushfirst!(params, tc)

            val = call!(builder, autodiff, params)

            ret!(builder, val)
        end

        LLVM.strip_debuginfo!(mod)
        if optimize
            # Run pipeline and Enzyme pass
            Compiler.optimize!(mod, llvmf, run_enzyme=run_enzyme)
        end

        new{rt}(mod, llvmf)
    end
end
return_type(::LLVMThunk{RT}) where RT = RT

struct Thunk{Ptr, RT, TT}
    function Thunk(f, tt)
        thunk = LLVMThunk(f, tt)
        triple = LLVM.triple()
        target = LLVM.Target(triple)
        objfile = tempname()
        libfile = tempname()
        TargetMachine(target, triple, "", "", LLVM.API.LLVMCodeGenLevelDefault, LLVM.API.LLVMRelocPIC) do tm
            LLVM.emit(tm, thunk.mod, LLVM.API.LLVMObjectFile, objfile)
        end

        run(`ld -shared $objfile -o $libfile`)
        libptr = Libdl.dlopen(libfile, Libdl.RTLD_LOCAL)
        ptr = Libdl.dlsym(libptr, :enzyme_entry)

        return new{ptr, return_type(thunk), Tuple{tt...}}()
    end
end

# https://github.com/JuliaGPU/GPUCompiler.jl/issues/3
# We are also re-running Julia's optimization pipeline again
# @generated function (thunk::Thunk{F, RT, TT, LLVMF})(args...) where {F, RT, TT, LLVMF}
#     _args = (:(args[$i]) for i in 1:length(args))
#     call_function(LLVMF, Float64, Tuple{args...}, Expr(:tuple, _args...))
# end

# Now this is just getting worse...
@generated function (thunk::Thunk{Ptr, RT})(args...) where {Ptr, RT}
    _args = (:(args[$i]) for i in 1:length(args))
    quote
        ccall($Ptr, $RT, ($(args...),), $(_args...))
    end
end

function enzyme_code_llvm(io::IO, @nospecialize(func), @nospecialize(types); 
                   optimize::Bool=true, run_enzyme::Bool=true, raw::Bool=false,
                   debuginfo::Symbol=:default, dump_module::Bool=false)
    thunk = LLVMThunk(func, types, optimize=optimize, run_enzyme=run_enzyme)

    str = ccall(:jl_dump_function_ir, Ref{String},
                (Ptr{Cvoid}, Bool, Bool, Ptr{UInt8}),
                LLVM.ref(thunk.entry), !raw, dump_module, debuginfo)
    print(io, str)
end
enzyme_code_llvm(@nospecialize(func), @nospecialize(types); kwargs...) = enzyme_code_llvm(stdout, func, types; kwargs...)

annotate() = ()
annotate(arg::Annotation, args...) = (arg, annotate(args...)...)
annotate(arg, args...) = (Const(arg), annotate(args...)...)

prepare_cc() = ()
prepare_cc(arg::Duplicated, args...) = (arg.val, arg.dval, prepare_cc(args...)...)
prepare_cc(arg::DuplicatedNoNeed, args...) = (arg.val, arg.dval, prepare_cc(args...)...)
prepare_cc(arg::Annotation, args...) = (arg.val, prepare_cc(args...)...)

function autodiff(f, args...)
    args′ =  annotate(args...)
    thunk = Thunk(f, map(Core.Typeof, args′))
    thunk(prepare_cc(args′...)...)
end

import .Compiler: EnzymeCtx
# Ops that have intrinsics
for op in (sin, cos, exp)
    for (T, suffix) in ((Float32, "f32"), (Float64, "f64"))
        llvmf = "llvm.$(nameof(op)).$suffix"
        @eval begin
            @inline function Cassette.overdub(::EnzymeCtx, ::typeof($op), x::$T)
                ccall($llvmf, llvmcall, $T, ($T,), x)
            end
        end
    end
end

for op in (asin,)
    for (T, llvm_t) in ((Float32, "float"), (Float64, "double"))
        decl = "declare double @$(nameof(op))($llvm_t)"
        func = """
               %val = call $llvm_t @asin($llvm_t %0)
               ret $llvm_t %val
               """
       @eval begin
            @inline function Cassette.overdub(::EnzymeCtx, ::typeof($op), x::$T)
                Base.llvmcall(($decl,$func), $T, Tuple{$T}, x)
            end
        end
    end
end

@inline function pack(args...)
    ntuple(Val(length(args))) do i
        Base.@_inline_meta
        arg = args[i]
        @assert arg isa AbstractFloat
        return Duplicated(Ref(args[i]), Ref(zero(args[i])))
    end
end

@inline unpack() = ()
@inline unpack(arg) = (arg[],)
@inline unpack(arg, args...) = (arg[], unpack(args...)...)

@inline ∇unpack() = ()
@inline ∇unpack(arg::Duplicated) = (arg.dval[],)
@inline ∇unpack(arg::Duplicated, args...) = (arg.dval[], ∇unpack(args...)...)

function gradient(f, args...)
    ∇args = pack(args...)
    f′ = function (args...)
        Base.@_inline_meta
        f(unpack(args...)...)
    end
    autodiff(f′, ∇args...)
    return ∇unpack(∇args...)
end

function pullback(f, args...)
    return (c) -> begin
        ∇vals = gradient(f, args...)
        return ntuple(Val(length(∇vals))) do i
            Base.@_inline_meta
            return c*∇vals[i]
        end
    end
end

# WIP
# @inline Cassette.overdub(::EnzymeCtx, ::typeof(asin), x::Float64) = ccall(:asin, Float64, (Float64,), x)
# @inline Cassette.overdub(::EnzymeCtx, ::typeof(asin), x::Float32) = ccall(:asin, Float32, (Float32,), x)
end # module
