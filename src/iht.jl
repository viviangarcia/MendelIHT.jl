"""
    L0_reg(x, xbm, z, y, J, k, d, l)

Runs Iterative Hard Thresholding for GWAS data `x`, response `y`, and non-genetic
covariates `z` on a specific sparsity parameter `k`. 

One needs to construct a SnpBitMatrix type (`xbm`) before running this function.

# Arguments:
+ `x`: A SnpArray, which can be memory mapped to a file. Does not engage in any linear algebra
+ `xbm`: The bitarray representation of `x`. This matrix is loaded in RAM and performs linear algebra. It's possible to set scale=false for xbm, especially when rare SNPs exist
+ `z`: Matrix of non-genetic covariates. The first column usually denotes the intercept. 
+ `y`: Response vector
+ `J`: The number of maximum groups (set as 1 if no group infomation available)
+ `k`: Number of non-zero predictors in each group
+ `d`: A distribution (e.g. Normal, Poisson)
+ `l`: A link function (e.g. Loglink, ProbitLink)

# Optional Arguments: 
+ `group` vector storing group membership
+ `weight` vector storing vector of weights containing prior knowledge on each SNP
+ `use_maf` indicates whether we want to scale the projection with minor allele frequencies (see paper)
+ `debias` is boolean indicating whether we debias at each iteration (see paper)
+ `show_info` boolean indicating whether we want to print results if model does not converge. Should set to false for multithread/multicore computing
+ `init` boolean indicating whether we want to initialize β to sensible values through fitting. This is not efficient yet. 
+ `tol` is used to track convergence
+ `max_iter` is the maximum IHT iteration for a model to converge. Defaults to 200, or 100 for cross validation
+ `max_step` is the maximum number of backtracking. Since l0 norm is not convex, we have no ascent guarantee
"""
function L0_reg(
    x         :: SnpArray,
    xbm       :: SnpBitMatrix,
    z         :: AbstractMatrix{T},
    y         :: AbstractVector{T},
    J         :: Int,
    k         :: Int,
    d         :: UnivariateDistribution,
    l         :: Link;
    group     :: AbstractVector{Int} = Int[],
    weight    :: AbstractVector{T} = T[],
    use_maf   :: Bool = false, 
    debias    :: Bool = false,
    show_info :: Bool = true,          # print things when model didn't converge
    init      :: Bool = false,         # not efficient. whether to initialize β to sensible values
    est_r     :: Int = 0,              # If 1, estimate r using MM algorithm. If 2, estimate r using Newton's Method
    tol       :: T = convert(T, 1e-4), # tolerance for tracking convergence
    max_iter  :: Int = 100,            # maximum IHT iterations
    max_step  :: Int = 5,              # maximum backtracking for each iteration
) where {T <: Float}

    #start timer
    start_time = time()

    # first handle errors
    @assert J >= 0        "Value of J (max number of groups) must be nonnegative!\n"
    @assert k >= 0        "Value of k (max predictors per group) must be nonnegative!\n"
    @assert max_iter >= 0 "Value of max_iter must be nonnegative!\n"
    @assert max_step >= 0 "Value of max_step must be nonnegative!\n"
    @assert tol > eps(T)  "Value of global tol must exceed machine precision!\n"
    checky(y, d) # make sure response data y is in the form compatible with specified GLM

    # initialize constants
    mm_iter     = 0                 # number of iterations 
    tot_time    = 0.0               # compute time *within* L0_reg
    next_logl   = oftype(tol,-Inf)  # loglikelihood
    the_norm    = 0.0               # norm(b - b0)
    scaled_norm = 0.0               # the_norm / (norm(b0) + 1)
    η_step      = 0                 # counts number of backtracking steps for η
    converged   = false             # scaled_norm < tol?

    # Initialize variables. 
    v = IHTVariables(x, z, y, J, k, group, weight)             # Placeholder variable for cleaner code
    full_grad = zeros(T, size(x, 2) + size(z, 2))              # Preallocated vector for efficiency
    init_iht_indices!(v, xbm, z, y, d, l, J, k)                # initialize non-zero indices
    copyto!(v.xk, @view(x[:, v.idx]), center=true, scale=true) # store relevant components of x for first iteration
    debias && (temp_glm = initialize_glm_object())             # Preallocated GLM variable for debiasing

    # If requested, compute initial guess for model b
    if init
        initialize_beta!(v, y, x, d, l)
        A_mul_B!(v.xb, v.zc, xbm, z, v.b, v.c)
    end

    # Begin 'iterative' hard thresholding algorithm
    for iter = 1:max_iter

        # notify and return current model if maximum iteration exceeded
        if iter >= max_iter
            mm_iter  = iter
            tot_time = time() - start_time
            show_info && printstyled("Did not converge after $max_iter iterations! The run time for IHT was " * string(tot_time) * " seconds and model size was" * string(k) * "\n", color=:red)
            break
        end

        # save values from previous iterate and update loglikelihood
        save_prev!(v)
        logl = next_logl

        # take one IHT step in positive score direction
        (η, η_step, next_logl, d) = iht_one_step!(v, x, xbm, z, y, J, k, d, l, logl, full_grad, iter, max_step, use_maf, est_r)

        # perform debiasing if requested
        if debias && sum(v.idx) == size(v.xk, 2)
            temp_glm = fit(GeneralizedLinearModel, v.xk, y, d, l)
            view(v.b, v.idx) .= temp_glm.pp.beta0
        end

        # track convergence
        the_norm    = max(chebyshev(v.b, v.b0), chebyshev(v.c, v.c0)) #max(abs(x - y))
        scaled_norm = the_norm / (max(norm(v.b0, Inf), norm(v.c0, Inf)) + 1.0)
        converged   = scaled_norm < tol
        if converged
        # if iter > 1 && abs(next_logl - logl) < tol * (abs(logl) + 1.0)
            tot_time = time() - start_time
            mm_iter  = iter
            break
        end
    end

    return ggIHTResults(tot_time, next_logl, mm_iter, v.b, v.c, J, k, v.group, d)
end #function L0_reg

"""
    L0_reg(x, z, y, J, k, d, l)

IHT algorithm that works on general matrices. 

# Arguments 
+ `x`: A general matrix. User should standardize it first. 
+ `z`: Other covariates. The column of intercept should go here.
+ `y`: Response vector
+ `J`: The number of maximum groups (set as 1 if no group infomation available)
+ `k`: Number of non-zero predictors in each group
+ `d`: A distribution (e.g. Normal, Poisson)
+ `l`: A link function (e.g. Loglink, ProbitLink)

# Optional Arguments
Optional arguments are the same as the `L0_reg` that works on SnpArrays.
"""
function L0_reg(
    x         :: AbstractMatrix{T},
    z         :: AbstractMatrix{T},
    y         :: AbstractVector{T},
    J         :: Int,
    k         :: Int,
    d         :: UnivariateDistribution,
    l         :: Link;
    group     :: AbstractVector{Int} = Int[],
    weight    :: AbstractVector{T} = T[],
    use_maf   :: Bool = false, 
    debias    :: Bool = false,
    show_info :: Bool = true,            # print things when model didn't converge
    init      :: Bool = false,           # not efficient. initializes β to sensible values
    est_r     :: Int  = 0,               # If 1, estimate r using MM algorithm. If 2, estimate r using Newton's Method
    tol       :: T    = convert(T, 1e-4),# tolerance for tracking convergence
    max_iter  :: Int  = 100,             # maximum IHT iterations
    max_step  :: Int  = 5,               # maximum backtracking for each iteration
) where {T <: Float}
    
    #start timer
    start_time = time()

    # first handle errors
    @assert J >= 0        "Value of J (max number of groups) must be nonnegative!\n"
    @assert k >= 0        "Value of k (max predictors per group) must be nonnegative!\n"
    @assert max_iter >= 0 "Value of max_iter must be nonnegative!\n"
    @assert max_step >= 0 "Value of max_step must be nonnegative!\n"
    @assert tol > eps(T)  "Value of global tol must exceed machine precision!\n"
    checky(y, d) # make sure response data y is in the form compatible with specified GLM

    # initialize constants
    mm_iter     = 0                 # number of iterations 
    tot_time    = zero(T)           # compute time *within* L0_reg
    next_logl   = oftype(tol,-Inf)  # loglikelihood
    the_norm    = zero(T)           # norm(b - b0)
    scaled_norm = zero(T)           # the_norm / (norm(b0) + 1)
    η_step      = 0                 # counts number of backtracking steps for η
    converged   = false             # scaled_norm < tol?

    # Initialize variables. 
    v = IHTVariables(x, z, y, J, k, group, weight) # Placeholder variable for cleaner code
    full_grad = zeros(T, size(x, 2) + size(z, 2))  # Preallocated vector for efficiency
    init_iht_indices!(v, x, z, y, d, l, J, k)      # initialize non-zero indices
    copyto!(v.xk, @view(x[:, v.idx]))              # store relevant components of x for first iteration
    debias && (temp_glm = initialize_glm_object()) # Preallocated GLM variable for debiasing

    # If requested, compute initial guess for model b
    if init
        initialize_beta!(v, y, x, d, l)
        A_mul_B!(v.xb, v.zc, x, z, v.b, v.c)
    end

    # Begin 'iterative' hard thresholding algorithm
    for iter = 1:max_iter

        # notify and return current model if maximum iteration exceeded
        if iter >= max_iter
            mm_iter  = iter
            tot_time = time() - start_time
            show_info && printstyled("Did not converge after $max_iter iterations! The run time for IHT was " * string(tot_time) * " seconds and model size was" * string(k) * "\n", color=:red)
            break
        end

        # save values from previous iterate and update loglikelihood
        save_prev!(v)
        logl = next_logl

        # take one IHT step in positive score direction
        (η, η_step, next_logl, d) = iht_one_step!(v, x, z, y, J, k, d, l, logl, full_grad, iter, max_step, use_maf, est_r)
        
        # perform debiasing if requested
        if debias && sum(v.idx) == size(v.xk, 2)
            temp_glm = fit(GeneralizedLinearModel, v.xk, y, d, l)
            view(v.b, v.idx) .= temp_glm.pp.beta0
        end

        # track convergence
        the_norm    = max(chebyshev(v.b, v.b0), chebyshev(v.c, v.c0)) #max(abs(x - y))
        scaled_norm = the_norm / (max(norm(v.b0, Inf), norm(v.c0, Inf)) + 1.0)
        converged   = scaled_norm < tol
        if converged
        # if iter > 1 && abs(next_logl - logl) < tol * (abs(logl) + 1.0)
            tot_time = time() - start_time
            mm_iter  = iter
            break
        end
    end

    return ggIHTResults(tot_time, next_logl, mm_iter, v.b, v.c, J, k, v.group, d)
end #function L0_reg

"""
This function performs 1 iteration of the IHT algorithm, backtracking a maximum of 5 times.
While IHT can strictly increase loglikelihood, we still allow it to potentially decrease 
to avoid bad boundary cases.
"""
function iht_one_step!(v::IHTVariable{T}, x::SnpArray, xbm::SnpBitMatrix, z::AbstractMatrix{T}, 
    y::AbstractVector{T}, J::Int, k::Int, d::UnivariateDistribution, l::Link, old_logl::T, 
    full_grad::AbstractVector{T}, iter::Int, nstep::Int, use_maf::Bool, est_r::Int) where {T <: Float}

    # first calculate step size 
    η = iht_stepsize(v, z, d, l)

    # update b and c by taking gradient step v.b = P_k(β + ηv) where v is the score direction
    _iht_gradstep(v, η, J, k, full_grad)

    # update the linear predictors `xb` with the new proposed b, and use that to compute the mean
    update_xb!(v, x, z)
    update_μ!(v.μ, v.xb + v.zc, l)
   
    # if Negative Binomial, save previous r and update
    if typeof(d) == NegativeBinomial{Float64}
        old_r = d.r

        # Using MM algorithm
        if est_r == 1
            d = update_r!(d, y, v.μ)

        # Using Newton's method
        elseif est_r == 2   
            new_r = mle_for_θ(y, v.μ, θ=d.r)
            d = NegativeBinomial(new_r, 0.5)
        end
    end

    # calculate current loglikelihood with the new computed xb and zc
    new_logl = loglikelihood(d, y, v.μ)

    η_step = 0
    while _iht_backtrack_(new_logl, old_logl, η_step, nstep)

        # stephalving
        η /= 2

        # if NegativeBinomial, reset r to previous r
        if typeof(d) == NegativeBinomial{Float64}
            d = NegativeBinomial(old_r, 0.5)
        end

        # recompute gradient step
        copyto!(v.b, v.b0)
        copyto!(v.c, v.c0)
        _iht_gradstep(v, η, J, k, full_grad)

        # recompute η = xb, μ = g(η), and loglikelihood to see if we're now increasing
        update_xb!(v, x, z)
        update_μ!(v.μ, v.xb + v.zc, l)

        # if Negative Binomial, update r
        if typeof(d) == NegativeBinomial{Float64}
            if est_r == 1
                d = update_r!(d, y, v.μ)
            elseif est_r == 2   
                new_r = mle_for_θ(y, v.μ, θ=d.r)
                d = NegativeBinomial(new_r, 0.5)
            end
        end

        new_logl = loglikelihood(d, y, v.μ)

        # increment the counter
        η_step += 1
    end

    # compute score with the new mean μ
    score!(d, l, v, xbm, z, y)

    # check for finiteness before moving to the next iteration
    isnan(new_logl) && throw(error("Loglikelihood function is NaN, aborting..."))
    isinf(new_logl) && throw(error("Loglikelihood function is Inf, aborting..."))
    isinf(η) && throw(error("step size not finite! it is $η and max gradient is " * string(maximum(v.gk)) * "!!\n"))

    return η::T, η_step::Int, new_logl::T, d::UnivariateDistribution
end #function iht_one_step

"""
Performs 1 iteration of the IHT algorithm given a general matrix of floating point numbers. 
"""
function iht_one_step!(v::IHTVariable{T}, x::AbstractMatrix, z::AbstractMatrix, 
    y::AbstractVector{T}, J::Int, k::Int, d::UnivariateDistribution, l::Link, old_logl::T, 
    full_grad::AbstractVector{T}, iter::Int, nstep::Int, use_maf::Bool, est_r::Int) where {T <: Float}

    # first calculate step size 
    η = iht_stepsize(v, z, d, l)

    # update b and c by taking gradient step v.b = P_k(β + ηv) where v is the score direction
    _iht_gradstep(v, η, J, k, full_grad)

    # update the linear predictors `xb` with the new proposed b, and use that to compute the mean
    update_xb!(v, x, z)
    update_μ!(v.μ, v.xb + v.zc, l)
    
    # if Negative Binomial, save previous r and update
    if typeof(d) == NegativeBinomial{Float64}
        old_r = d.r

        # Using MM algorithm
        if est_r == 1
            d = update_r!(d, y, v.μ)

        # Using Newton's method
        elseif est_r == 2   
            new_r = mle_for_θ(y, v.μ, θ=d.r)
            d = NegativeBinomial(new_r, 0.5)
        end
    end

    # calculate current loglikelihood with the new computed xb and zc
    new_logl = loglikelihood(d, y, v.μ)

    η_step = 0
    while _iht_backtrack_(new_logl, old_logl, η_step, nstep)

        # stephalving
        η /= 2

        # If NegativeBinomial, reset r to previous r
        if typeof(d) == NegativeBinomial{Float64}
            d = NegativeBinomial(old_r, 0.5)
        end

        # recompute gradient step
        copyto!(v.b, v.b0)
        copyto!(v.c, v.c0)
        _iht_gradstep(v, η, J, k, full_grad)

        # recompute η = xb, μ = g(η), and loglikelihood to see if we're now increasing
        update_xb!(v, x, z)
        update_μ!(v.μ, v.xb + v.zc, l)
        
        # If NegativeBinomial, update r
        if typeof(d) == NegativeBinomial{Float64}
            if est_r == 1
                d = update_r!(d, y, v.μ)
            elseif est_r == 2
                new_r = mle_for_θ(y, v.μ, θ=d.r)
                d = NegativeBinomial(new_r, 0.5)
            end
        end

        new_logl = loglikelihood(d, y, v.μ)

        # increment the counter
        η_step += 1
    end

    # compute score with the new mean μ
    score!(d, l, v, x, z, y)

    # check for finiteness before moving to the next iteration
    isnan(new_logl) && throw(error("Loglikelihood function is NaN, aborting..."))
    isinf(new_logl) && throw(error("Loglikelihood function is Inf, aborting..."))
    isinf(η) && throw(error("step size not finite! it is $η and max gradient is " * string(maximum(v.gk)) * "!!\n"))

    return η::T, η_step::Int, new_logl::T, d::UnivariateDistribution
end #function iht_one_step
