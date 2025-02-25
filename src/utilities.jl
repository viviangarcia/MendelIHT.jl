"""
    loglikelihood(d::UnivariateDistribution, y::AbstractVector, μ::AbstractVector)

Calculates the loglikelihood of observing `y` given mean `μ` and some distribution 
`d`. 

Note that loglikelihood is the sum of the logpdfs for each observation. 
For each logpdf from Normal, Gamma, and InverseGaussian, we scale by dispersion. 
"""
function loglikelihood(d::UnivariateDistribution, y::AbstractVector{T}, 
                       μ::AbstractVector{T}) where {T <: Float}
    logl = 0.0
    ϕ = MendelIHT.deviance(d, y, μ) / length(y)
    @inbounds for i in eachindex(y)
        logl += loglik_obs(d, y[i], μ[i], 1, ϕ) #wt = 1 because only have 1 sample to estimate a given mean 
    end
    return T(logl)
end

"""
This function is taken from GLM.jl from: 
https://urldefense.proofpoint.com/v2/url?u=https-3A__github.com_JuliaStats_GLM.jl_blob_956a64e7df79e80405867238781f24567bd40c78_src_glmtools.jl-23L445&d=DwIGaQ&c=sJ6xIWYx-zLMB3EPkvcnVg&r=7sbWVWEGF5cmtB61wl7FFg&m=t0UYMxl1l6T9gQwevDjzKZl1EUq7cxc1N1Q251BQAUU&s=T5Tp_cvAeqiX2CbgYRm0yhX-Uzmeg5rRbOXvyDiwq_M&e= 

Putting it here because it was not exported. 

`wt`: the number of observations (y) used to estimate μ
"""
function loglik_obs end

loglik_obs(::Bernoulli, y, μ, wt, ϕ) = wt*logpdf(Bernoulli(μ), y)
loglik_obs(::Binomial, y, μ, wt, ϕ) = logpdf(Binomial(Int(wt), μ), Int(y*wt))
loglik_obs(::Gamma, y, μ, wt, ϕ) = wt*logpdf(Gamma(inv(ϕ), μ*ϕ), y)
loglik_obs(::InverseGaussian, y, μ, wt, ϕ) = wt*logpdf(InverseGaussian(μ, inv(ϕ)), y)
loglik_obs(::Normal, y, μ, wt, ϕ) = wt*logpdf(Normal(μ, sqrt(ϕ)), y)
loglik_obs(::Poisson, y, μ, wt, ϕ) = wt*logpdf(Poisson(μ), y)
# We use the following parameterization for the Negative Binomial distribution:
#    (Γ(θ+y) / (Γ(θ) * y!)) * μ^y * θ^θ / (μ+θ)^{θ+y}
# The parameterization of NegativeBinomial(r=θ, p) in Distributions.jl is
#    Γ(θ+y) / (y! * Γ(θ)) * p^θ(1-p)^y
# Hence, p = θ/(μ+θ)
loglik_obs(d::NegativeBinomial, y, μ, wt, ϕ) = wt*logpdf(NegativeBinomial(d.r, d.r/(μ+d.r)), y)

"""
The deviance of a GLM can be evaluated as the sum of the squared deviance residuals. Calculation
of sqared deviance residuals is accomplished by `devresid` which is implemented in GLM.jl
"""
function deviance(d::UnivariateDistribution, y::AbstractVector{T}, μ::AbstractVector{T}) where {T <: Float}
    dev = 0.0
    @inbounds for i in eachindex(y)
        dev += devresid(d, y[i], μ[i])
    end
    return dev
end

function update_μ!(μ::AbstractVector{T}, xb::AbstractVector{T}, l::Link) where {T <: Float}
    @inbounds for i in eachindex(μ)
        μ[i] = linkinv(l, xb[i])
    end
end

"""
This function update the linear predictors `xb` with the new proposed b. We clamp the max
value of each entry to (-20, 20) because certain distributions (e.g. Poisson) have exponential
link functions, which causes overflow.
"""
function update_xb!(v::IHTVariable{T}, x::Union{SnpArray, AbstractMatrix}, 
                    z::AbstractMatrix{T}) where {T <: Float}
    typeof(x) == SnpArray ? copyto!(v.xk, @view(x[:, v.idx]), center=true, scale=true) : copyto!(v.xk, @view(x[:, v.idx]))
    A_mul_B!(v.xb, v.zc, v.xk, z, view(v.b, v.idx), v.c)
    clamp!(v.xb, -20, 20)
    clamp!(v.zc, -20, 20)
end

# For NegativeBinomial
function update_r!(d::NegativeBinomial, y::AbstractVector{T}, μ::AbstractVector{T}) where {T <: Float}
    num = zero(T)
    den = zero(T)
    for i in eachindex(y)
        for j = 0:y[i] - 1
            num = num + (d.r /(d.r + j))  # numerator for r
        end
        p = d.r / (d.r + μ[i])
        den = den + log(p)  # denominator for r
    end
    new_r = -(num)/den
    d = NegativeBinomial(new_r, d.p)
    return d
end



"""
    score = X^T * W * (y - g(x^T b))

Calculates the score (gradient) for different glm models. 

W is a diagonal matrix where w[i, i] = g'(x^T b) / var(μ). 
"""
function score!(d::UnivariateDistribution, l::Link, v::IHTVariable{T}, 
                x::Union{SnpBitMatrix, AbstractMatrix}, z::AbstractMatrix{T}, 
                y::AbstractVector{T}) where {T <: Float}
    @inbounds for i in eachindex(y)
        # η = clamp(v.xb[i] + v.zc[i], -20, 20)
        η = v.xb[i] + v.zc[i]
        w = mueta(l, η) / glmvar(d, v.μ[i])
        v.r[i] = w * (y[i] - v.μ[i])
    end
    At_mul_B!(v.df, v.df2, x, z, v.r, v.r)
end

"""
This function computes the gradient step v.b = P_k(β + η∇f(β)) and updates idx and idc. 
"""
function _iht_gradstep(v::IHTVariable{T}, η::T, J::Int, k::Int, 
                       full_grad::Vector{T}) where {T <: Float}
    lb = length(v.b)
    lw = length(v.weight)
    lg = length(v.group)
    lf = length(full_grad)

    # take gradient step: b = b + ηv, v = score
    BLAS.axpy!(η, v.df, v.b)  
    BLAS.axpy!(η, v.df2, v.c)

    # scale model by weight vector, if supplied 
    if lw == 0
        copyto!(@view(full_grad[1:lb]), v.b)
        copyto!(@view(full_grad[lb+1:lf]), v.c)
    else
        copyto!(@view(full_grad[1:lb]), v.b .* @view(v.weight[1:lb]))
        copyto!(@view(full_grad[lb+1:lf]), v.c .* @view(v.weight[lb+1:lf]))
    end

    # project to sparsity
    lg == 0 ? project_k!(full_grad, k) : project_group_sparse!(full_grad, v.group, J, k)
    
    # unweight the model after projection
    if lw == 0
        copyto!(v.b, @view(full_grad[1:lb]))
        copyto!(v.c, @view(full_grad[lb+1:lf]))
    else
        copyto!(v.b, @view(full_grad[1:lb]) ./ @view(v.weight[1:lb]))
        copyto!(v.c, @view(full_grad[lb+1:lf]) ./ @view(v.weight[lb+1:lf]))
    end

    #recombute support
    v.idx .= v.b .!= 0
    v.idc .= v.c .!= 0
    
    # if more than J*k entries are selected, randomly choose J*k of them
    _choose!(v, J, k) 

    # make necessary resizing since grad step might include/exclude non-genetic covariates
    check_covariate_supp!(v) 
end

"""
When initializing the IHT algorithm, take largest elements in magnitude of each group of 
the score as nonzero components of b. This function set v.idx = 1 for those indices. 

`J` is the maximum number of active groups, and `k` is the maximum number of predictors per
group. 
"""
function init_iht_indices!(v::IHTVariable{T}, x::Union{SnpBitMatrix, AbstractMatrix}, 
                           z::AbstractMatrix{T},y::Vector{T}, d::UnivariateDistribution, 
                           l::Link, J::Int, k::Int) where {T <: Float}
    # find the intercept by Newton's method
    ybar = mean(y)
    for iteration = 1:20 
        g1 = linkinv(l, v.c[1])
        g2 = mueta(l, v.c[1])
        v.c[1] = v.c[1] - clamp((g1 - ybar) / g2, -1.0, 1.0)
        abs(g1 - ybar) < 1e-10 && break
    end
    v.zc .= z * v.c

    # update mean vector and use them to compute score (gradient)
    update_μ!(v.μ, v.xb + v.zc, l)
    score!(d, l, v, x, z, y)

    # find J*k largest entries in magnitude and set everything else to 0. 
    a = partialsort([v.df; v.df2], k * J, by=abs, rev=true)
    v.idx .= abs.(v.df) .>= abs(a)
    v.idc .= abs.(v.df2) .>= abs(a)

    # Choose randomly if more are selected
    _choose!(v, J, k) 

    # make necessary resizing when necessary
    check_covariate_supp!(v)
end

"""
if more than J*k entries are selected after projection, randomly select top J*k entries.
This can happen if entries of b are equal to each other.
"""
function _choose!(v::IHTVariable{T}, J::Int, k::Int) where {T <: Float}
    while sum(v.idx) + sum(v.idc) > J * k
        idx_length = length(v.idx)
        all_idx = [v.idx; v.idc]

        nonzero_idx = findall(x -> x == true, all_idx) #find non-0 location
        pos = nonzero_idx[rand(1:length(nonzero_idx))] #randomly set a non-0 entry to 0
        pos > idx_length ? v.idc[pos - idx_length] = 0 : v.idx[pos] = 0
    end
end

"""
In `_init_iht_indices` and `_iht_gradstep`, if non-genetic cov got 
included/excluded, we must resize xk and gk
"""
function check_covariate_supp!(v::IHTVariable{T}) where {T <: Float}
    if sum(v.idx) != size(v.xk, 2)
        v.xk = zeros(T, size(v.xk, 1), sum(v.idx))
        v.gk = zeros(T, sum(v.idx))
    end
end

"""
This function returns true if backtracking condition is met. Currently, backtracking condition
includes either one of the following:
    1. New loglikelihood is smaller than the old one
    2. Current backtrack (`η_step`) exceeds maximum allowed backtracking (`nstep`, default = 3)

Note for Posison, NegativeBinomial, and Gamma, we require model coefficients to be 
"small" to prevent loglikelihood blowing up in first few iteration. This is accomplished 
by clamping η = xb values to be in (-20, 20)
"""
function _iht_backtrack_(logl::T, prev_logl::T, η_step::Int64, nstep::Int64) where {T <: Float}
    (prev_logl > logl) && (η_step < nstep)
end

"""
    std_reciprocal(x::SnpBitMatrix, mean_vec::Vector{T})

Compute the standard error of each columns of a SnpArray in place. 

`mean_vec` stores the mean for each SNP. Note this function assumes all SNPs 
are not missing. Otherwise, the inner loop should only add if data not missing.
"""
function std_reciprocal(x::SnpBitMatrix, mean_vec::Vector{T}) where {T <: Float}
    m, n = size(x)
    @assert n == length(mean_vec) "number of columns of snpmatrix doesn't agree with length of mean vector"
    std_vector = zeros(T, n)

    @inbounds for j in 1:n
        @simd for i in 1:m
            a1 = x.B1[i, j]
            a2 = x.B2[i, j]
            std_vector[j] += (convert(T, a1 + a2) - mean_vec[j])^2
        end
        std_vector[j] = 1.0 / sqrt(std_vector[j] / (m - 1))
    end
    return std_vector
end

"""
    standardize!(z::Matrix{Float64})

Standardizes each column of `z` to mean 0 and variance 1. Make sure you 
do not standardize the intercept. 
"""
@inline function standardize!(z::AbstractMatrix{Float64})
    n, q = size(z)
    μ = _mean(z)
    σ = _std(z, μ)

    @inbounds for j in 1:q
        @simd for i in 1:n
            z[i, j] = (z[i, j] - μ[j]) * σ[j]
        end
    end
end

@inline function _mean(z::AbstractMatrix{Float64})
    n, q = size(z)
    μ = zeros(q)
    @inbounds for j in 1:q
        tmp = 0.0
        @simd for i in 1:n
            tmp += z[i, j]
        end
        μ[j] = tmp / n
    end
    return μ
end

function _std(z::AbstractMatrix{Float64}, μ::Vector{Float64})
    n, q = size(z)
    σ = zeros(q)

    @inbounds for j in 1:q
        @simd for i in 1:n
            σ[j] += (z[i, j] - μ[j])^2
        end
        σ[j] = 1.0 / sqrt(σ[j] / (n - 1))
    end
    return σ
end

"""
    project_k!(x::AbstractVector, k::Integer)

Sets all but the largest `k` entries of `x` to 0. 

# Examples:
```julia-repl
using MendelIHT
x = [1.0; 2.0; 3.0]
project_k!(x, 2) # keep 2 largest entry
julia> x
3-element Array{Float64,1}:
 0.0
 2.0
 3.0
```

# Arguments:
- `x`: the vector to project.
- `k`: the number of components of `x` to preserve.
"""
function project_k!(x::AbstractVector{T}, k::Int64) where {T <: Float}
    a = abs(partialsort(x, k, by=abs, rev=true))
    @inbounds for i in eachindex(x)
        abs(x[i]) < a && (x[i] = zero(T))
    end
end

""" 
    project_group_sparse!(y::AbstractVector, group::AbstractVector, J::Integer, k::Integer)

Projects the vector y onto the set with at most J active groups and at most
k active predictors per group. Currently assumes there are no unknown or overlaping 
group membership.

# Examples
```julia-repl
using MendelIHT
J, k, n = 2, 3, 20
y = collect(1.0:20.0)
y_copy = copy(y)
group = rand(1:5, n)
project_group_sparse!(y, group, J, k)
for i = 1:length(y)
    println(i,"  ",group[i],"  ",y[i],"  ",y_copy[i])
end
```

# Arguments 
- `y`: The vector to project
- `group`: Vector encoding group membership
- `J`: Max number of non-zero group
- `k`: Max number of non-zero predictor per group`
"""
function project_group_sparse!(y::AbstractVector{T}, group::AbstractVector{Int64},
    J::Int64, k::Int64) where {T <: Float}
    groups = maximum(group)          # number of groups
    group_count = zeros(Int, groups) # counts number of predictors in each group
    group_norm = zeros(groups)       # l2 norm of each group
    perm = zeros(Int64, length(y))   # vector holding the permuation vector after sorting
    sortperm!(perm, y, by = abs, rev = true)

    #calculate the magnitude of each group, where only top predictors contribute
    for i in eachindex(y)
        j = perm[i]
        n = group[j]
        if group_count[n] < k
            group_norm[n] = group_norm[n] + y[j]^2
            group_count[n] = group_count[n] + 1
        end
    end

    #go through the top predictors in order. Set predictor to 0 if criteria not met
    group_rank = zeros(Int64, length(group_norm))
    sortperm!(group_rank, group_norm, rev = true)
    group_rank = invperm(group_rank)
    fill!(group_count, 1)
    for i in eachindex(y)
        j = perm[i]
        n = group[j]
        if (group_rank[n] > J) || (group_count[n] > k)
            y[j] = 0.0
        else
            group_count[n] = group_count[n] + 1
        end
    end
end

"""
    maf_weights(x::SnpArray; max_weight::T = Inf)

Calculates the prior weight based on minor allele frequencies. 

Returns an array of weights where `w[i] = 1 / (2 * sqrt(p[i] (1 - p[i]))) ∈ (1, ∞).`
Here `p` is the minor allele frequency computed by `maf()` in SnpArrays. 

- `x`: A SnpArray 
- `max_weight`: Maximum weight for any predictor. Defaults to `Inf`. 
"""
function maf_weights(x::SnpArray; max_weight::T = Inf) where {T <: Float}
    p = maf(x)
    p .= 1 ./ (2 .* sqrt.(p .* (1 .- p)))
    clamp!(p, 1.0, max_weight)
    return p
end

"""
Function that saves `b`, `xb`, `idx`, `idc`, `c`, and `zc` after each iteration. 
"""
function save_prev!(v::IHTVariable{T}) where {T <: Float}
    copyto!(v.b0, v.b)     # b0 = b
    copyto!(v.xb0, v.xb)   # Xb0 = Xb
    copyto!(v.idx0, v.idx) # idx0 = idx
    copyto!(v.idc0, v.idc) # idc0 = idc
    copyto!(v.c0, v.c)     # c0 = c
    copyto!(v.zc0, v.zc)   # Zc0 = Zc
end

"""
Computes the best step size η = v'v / v'Jv

Here v is the score and J is the expected information matrix, which is 
computed by J = g'(xb) / var(μ), assuming dispersion is 1
"""
function iht_stepsize(v::IHTVariable{T}, z::AbstractMatrix{T}, 
                      d::UnivariateDistribution, l::Link) where {T <: Float}
    
    # first store relevant components of gradient
    copyto!(v.gk, view(v.df, v.idx))
    A_mul_B!(v.xgk, v.zdf2, v.xk, view(z, :, v.idc), v.gk, view(v.df2, v.idc))
    
    #use zdf2 as temporary storage
    v.xgk .+= v.zdf2
    v.zdf2 .= mueta.(l, v.xb + v.zc).^2 ./ glmvar.(d, v.μ)

    # now compute and return step size. Note non-genetic covariates are separated from x
    numer = sum(abs2, v.gk) + sum(abs2, @view(v.df2[v.idc]))
    denom = Transpose(v.xgk) * Diagonal(v.zdf2) * v.xgk
    return (numer / denom) :: T
end

"""
This is a wrapper linear algebra function that computes [C1 ; C2] = [A1 ; A2] * [B1 ; B2] 
where A1 is a snpmatrix and A2 is a dense Matrix{Float}. Used for cleaner code. 

Here we are separating the computation because A1 is stored in compressed form while A2 is 
uncompressed (float64) matrix. This means that they cannot be stored in the same data 
structure. 
"""
function A_mul_B!(C1::AbstractVector{T}, C2::AbstractVector{T}, A1::SnpBitMatrix{T},
        A2::AbstractMatrix{T}, B1::AbstractVector{T}, B2::AbstractVector{T}) where {T <: Float}
    SnpArrays.mul!(C1, A1, B1)
    LinearAlgebra.mul!(C2, A2, B2)
end

function A_mul_B!(C1::AbstractVector{T}, C2::AbstractVector{T}, A1::AbstractMatrix{T},
        A2::AbstractMatrix{T}, B1::AbstractVector{T}, B2::AbstractVector{T}) where {T <: Float}
    LinearAlgebra.mul!(C1, A1, B1)
    LinearAlgebra.mul!(C2, A2, B2)
end

"""
    initialize_beta!(v::IHTVariable, y::AbstractVector, x::SnpArray, d::UnivariateDistribution, l::Link)

Fits a univariate regression (+ intercept) with each β_i corresponding to `x`'s predictor.

Used to find a good starting β. Fitting is done using scoring (newton) algorithm 
implemented in `GLM.jl`. The intial intercept is separately fitted using in init_iht_indices(). 

Note: this function is quite slow and not memory efficient. 
"""
function initialize_beta!(v::IHTVariable{T}, y::AbstractVector{T}, x::Union{SnpArray, AbstractMatrix},
                          d::UnivariateDistribution, l::Link) where {T <: Float}
    n, p = size(x)
    temp_matrix = ones(n, 2)           # n by 2 matrix of the intercept and 1 single covariate
    temp_glm = initialize_glm_object() # preallocating in a dumb ways

    intercept = 0.0
    if typeof(x) == SnpArray
        for i in 1:p
            copyto!(@view(temp_matrix[:, 2]), @view(x[:, i]), center=true, scale=true)
            temp_glm = fit(GeneralizedLinearModel, temp_matrix, y, d, l)
            v.b[i] = temp_glm.pp.beta0[2]
        end
    else 
        for i in 1:p
            temp_matrix[:, 2] .= x[:, i]
            temp_glm = fit(GeneralizedLinearModel, temp_matrix, y, d, l)
            v.b[i] = temp_glm.pp.beta0[2]
        end
    end
end

"""
This is a wrapper linear algebra function that computes [C1 ; C2] = [A1 ; A2]^T * [B1 ; B2] 
where A1 is a snpmatrix and A2 is a dense Matrix{Float}. Used for cleaner code. 

Here we are separating the computation because A1 is stored in compressed form while A2 is 
uncompressed (float64) matrix. This means that they cannot be stored in the same data 
structure. 
"""
function At_mul_B!(C1::AbstractVector{T}, C2::AbstractVector{T}, A1::SnpBitMatrix{T},
        A2::AbstractMatrix{T}, B1::AbstractVector{T}, B2::AbstractVector{T}) where {T <: Float}
    SnpArrays.mul!(C1, Transpose(A1), B1)
    LinearAlgebra.mul!(C2, Transpose(A2), B2)
end

function At_mul_B!(C1::AbstractVector{T}, C2::AbstractVector{T}, A1::AbstractMatrix{T},
        A2::AbstractMatrix{T}, B1::AbstractVector{T}, B2::AbstractVector{T}) where {T <: Float}
    LinearAlgebra.mul!(C1, Transpose(A1), B1)
    LinearAlgebra.mul!(C2, Transpose(A2), B2)
end

"""
This function initializes 1 instance of a GeneralizedLinearModel(G<:GlmResp, L<:LinPred, Bool). 
"""
function initialize_glm_object()
    d = Bernoulli
    l = canonicallink(d())
    x = rand(100, 2)
    y = rand(0:1, 100)
    return fit(GeneralizedLinearModel, x, y, d(), l)
end

function mle_for_θ(y::AbstractVector, μ::AbstractVector; 
                    θ::AbstractFloat = 1.0, maxIter=100, convTol=1.e-6)

    function first_derivative(θ::Real)
        tmp(yi, μi) = -(yi+θ)/(μi+θ) - log(μi+θ) + 1 + log(θ) + digamma(θ+yi) - digamma(θ)
        return sum(tmp(yi, μi) for (yi, μi) in zip(y, μ))
    end

    function second_derivative(θ::Real)
        tmp(yi, μi) = (yi+θ)/(μi+θ)^2 - 2/(μi+θ) + 1/θ + trigamma(θ+yi) - trigamma(θ)
        return sum(tmp(yi, μi) for (yi, μi) in zip(y, μ))
    end

    function negbin_loglikelihood(θ::Real)
        d_newton = NegativeBinomial(θ, 0.5)
        return MendelIHT.loglikelihood(d_newton, y, μ)
    end

    function newton_increment(θ::Real)
        # use gradient descent if hessian not positive definite
        dx  = first_derivative(θ)
        dx2 = second_derivative(θ)
        if dx2 < 0
            increment = first_derivative(θ) / second_derivative(θ)
        else 
            increment = first_derivative(θ)
        end
        # println(dx2)
        return increment
    end

    new_θ    = 1.0
    stepsize = 1.0
    for i in 1:maxIter

        # run 1 iteration of Newton's algorithm
        increment = newton_increment(θ)
        new_θ = θ - stepsize * increment

        # linesearch
        old_logl = negbin_loglikelihood(θ)
        for j in 1:20
            if new_θ <= 0
                stepsize = stepsize / 2
                new_θ = θ - stepsize * increment
            else 
                new_logl = negbin_loglikelihood(new_θ)
                if old_logl >= new_logl
                    stepsize = stepsize / 2
                    new_θ = θ - stepsize * increment
                else
                    break
                end
            end
        end

        #check convergence
        if abs(θ - new_θ) <= convTol
            return new_θ
        else
            θ = new_θ
        end
    end

    return θ
end

"""
    naive_impute(x, destination)

Imputes missing entries of a SnpArray using the mode of each SNP, and
saves the result in a new file called destination in current directory. 
Non-missing entries are the same. 
"""
function naive_impute(x::SnpArray, destination::String)
    n, p = size(x)
    y = SnpArray(destination, n, p)

    @inbounds for j in 1:p

        #identify mode
        entry0, entry1, entry2 = 0, 0, 0
        for i in 1:n
            if x[i, j] == 0x00 
                y[i, j] = 0x00
                entry0 += 1
            elseif x[i, j] == 0x02 
                y[i, j] = 0x02
                entry1 += 1
            elseif x[i, j] == 0x03 
                y[i, j] = 0x03
                entry2 += 1
            end
        end
        most_often = max(entry0, entry1, entry2)
        missing_entry = 0x00
        if most_often == entry1
            missing_entry = 0x02
        elseif most_often == entry2
            missing_entry = 0x03
        end

        # impute 
        for i in 1:n
            if x[i, j] == 0x01 
                y[i, j] = missing_entry
            end
        end
    end

    return nothing
end
