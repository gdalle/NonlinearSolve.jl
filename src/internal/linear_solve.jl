import LinearSolve: AbstractFactorization, DefaultAlgorithmChoice, DefaultLinearSolver

@concrete mutable struct LinearSolverCache <: AbstractLinearSolverCache
    lincache
    linsolve
    A
    b
    precs
    nsolve::Int
    nfactors::Int
end

# FIXME: Do we need to reinit the precs?
function reinit_cache!(cache::LinearSolverCache, args...; kwargs...)
    cache.nsolve = 0
    cache.nfactors = 0
end

@inline function LinearSolverCache(alg, linsolve, A::Number, b::Number, u; kwargs...)
    return LinearSolverCache(nothing, nothing, A, b, nothing, 0, 0)
end
@inline function LinearSolverCache(alg, ::Nothing, A::SMatrix, b, u; kwargs...)
    # Default handling for SArrays caching in LinearSolve is not the best. Override it here
    return LinearSolverCache(nothing, nothing, A, b, nothing, 0, 0)
end
@inline function LinearSolverCache(alg, linsolve, A::Diagonal, b, u; kwargs...)
    return LinearSolverCache(nothing, nothing, A, b, nothing, 0, 0)
end
function LinearSolverCache(alg, linsolve, A, b, u; kwargs...)
    @bb b_ = copy(b)
    @bb u_ = copy(u)
    linprob = LinearProblem(A, b_; u0 = u_, kwargs...)

    weight = __init_ones(u)
    if __hasfield(alg, Val(:precs))
        precs = alg.precs
        Pl_, Pr_ = precs(A, nothing, u, nothing, nothing, nothing, nothing, nothing,
            nothing)
    else
        precs, Pl_, Pr_ = nothing, nothing, nothing
    end
    Pl, Pr = __wrapprecs(Pl_, Pr_, weight)

    # Unalias here, we will later use these as caches
    lincache = init(linprob, linsolve; alias_A = false, alias_b = false, Pl, Pr)

    return LinearSolverCache(lincache, linsolve, nothing, nothing, precs, 0, 0)
end

# Direct Linear Solve Case without Caching
function (cache::LinearSolverCache{Nothing})(; A = nothing, b = nothing, linu = nothing,
        kwargs...)
    cache.nsolve += 1
    cache.nfactors += 1
    A === nothing || (cache.A = A)
    b === nothing || (cache.b = b)
    if A isa Diagonal
        _diag = _restructure(cache.b, cache.A.diag)
        @bb @. linu = cache.b / _diag
        res = linu
    else
        res = cache.A \ cache.b
    end
    return res
end
# Use LinearSolve.jl
function (cache::LinearSolverCache)(; A = nothing, b = nothing, linu = nothing,
        du = nothing, p = nothing, weight = nothing, cachedata = nothing,
        reuse_A_if_factorization = false, kwargs...)
    cache.nsolve += 1

    __update_A!(cache, A, reuse_A_if_factorization)
    b !== nothing && (cache.lincache.b = b)
    linu !== nothing && (cache.lincache.u = linu)

    Plprev = cache.lincache.Pl isa ComposePreconditioner ? cache.lincache.Pl.outer :
             cache.lincache.Pl
    Prprev = cache.lincache.Pr isa ComposePreconditioner ? cache.lincache.Pr.outer :
             cache.lincache.Pr

    if cache.precs === nothing
        _Pl, _Pr = nothing, nothing
    else
        _Pl, _Pr = cache.precs(cache.lincache.A, du, linu, p, nothing, A !== nothing,
            Plprev, Prprev, cachedata)
    end

    if (_Pl !== nothing || _Pr !== nothing)
        _weight = weight === nothing ?
                  (cache.lincache.Pr isa Diagonal ? cache.lincache.Pr.diag :
                   cache.lincache.Pr.inner.diag) : weight
        Pl, Pr = __wrapprecs(_Pl, _Pr, _weight)
        cache.lincache.Pl = Pl
        cache.lincache.Pr = Pr
    end

    linres = solve!(cache.lincache)
    cache.lincache = linres.cache

    return linres.u
end

@inline __update_A!(cache::LinearSolverCache, ::Nothing, reuse) = cache
@inline function __update_A!(cache::LinearSolverCache, A, reuse)
    return __update_A!(cache, __getproperty(cache.lincache, Val(:alg)), A, reuse)
end
@inline function __update_A!(cache, alg, A, reuse)
    # Not a Factorization Algorithm so don't update `nfactors`
    __set_lincache_A(cache.lincache, A)
    return cache
end
@inline function __update_A!(cache, ::AbstractFactorization, A, reuse)
    reuse && return cache
    __set_lincache_A(cache.lincache, A)
    cache.nfactors += 1
    return cache
end
@inline function __update_A!(cache, alg::DefaultLinearSolver, A, reuse)
    if alg == DefaultLinearSolver(DefaultAlgorithmChoice.KrylovJL_GMRES)
        # Force a reset of the cache. This is not properly handled in LinearSolve.jl
        __set_lincache_A(cache.lincache, A)
        return cache
    end
    reuse && return cache
    __set_lincache_A(cache.lincache, A)
    cache.nfactors += 1
    return cache
end

function __set_lincache_A(lincache, new_A)
    if LinearSolve.default_alias_A(lincache.alg, new_A, lincache.b)
        lincache.A = new_A
    else
        if can_setindex(lincache.A)
            copyto!(lincache.A, new_A)
            lincache.A = lincache.A
        else
            lincache.A = new_A
        end
    end
end

@inline function __wrapprecs(_Pl, _Pr, weight)
    if _Pl !== nothing
        Pl = ComposePreconditioner(InvPreconditioner(Diagonal(_vec(weight))), _Pl)
    else
        Pl = InvPreconditioner(Diagonal(_vec(weight)))
    end

    if _Pr !== nothing
        Pr = ComposePreconditioner(Diagonal(_vec(weight)), _Pr)
    else
        Pr = Diagonal(_vec(weight))
    end

    return Pl, Pr
end

@inline __needs_square_A(_, ::Number) = false
@inline __needs_square_A(::Nothing, ::Number) = false
@inline __needs_square_A(::Nothing, _) = false
@inline __needs_square_A(linsolve, _) = LinearSolve.needs_square_A(linsolve)
