"""
Object to contain intermediate variables and temporary arrays. Used for cleaner code in L0_reg
"""
mutable struct IHTVariable{T <: Float, V <: DenseVector}
   b    :: Vector{T}     # the statistical model, most will be 0
   b0   :: Vector{T}     # previous estimated model in the mm step
   xb   :: Vector{T}     # vector that holds x*b 
   xb0  :: Vector{T}     # previous xb in the mm step
   xk   :: SnpArray{2}   # the n by k subset of the design matrix x corresponding to non-0 elements of b
   gk   :: Vector{T}     # Numerator of step size μ.   gk = df[idx] is a temporary array of length `k` that arises as part of the gradient calculations. I avoid doing full gradient calculations since most of `b` is zero. 
   xgk  :: Vector{T}     # Demonimator of step size μ. x * gk also part of the gradient calculation 
   idx  :: BitArray{1}   # BitArray indices of nonzeroes in b for A_mul_B
   idx0 :: BitArray{1}   # previous iterate of idx
   r    :: V             # n-vector of residuals
   df   :: V             # the gradient: df = -x' * (y - xb)
end

function IHTVariables{T <: Float}(
    x :: SnpData,
    y :: Vector{T},
    k :: Int64
) 
    n, p = x.people, x.snps #adding 1 for p because we need an intercept

    #check if k is sensible
    if k > p;  throw(ArgumentError("k cannot exceed the number of SNPs")); end
    if k <= 0; throw(ArgumentError("k must be positive integer")); end

    b    = zeros(T, p)
    b0   = zeros(T, p)
    xb   = zeros(T, n)
    xb0  = zeros(T, n)
    xk   = SnpArray(n, k)
    gk   = zeros(T, k)
    xgk  = zeros(T, n)
    idx  = falses(p) 
    idx0 = falses(p)
    r    = zeros(T, n)
    df   = zeros(T, p)
    return IHTVariable{T, typeof(y)}(b, b0, xb, xb0, xk, gk, xgk, idx, idx0, r, df)
end

#immutable IHTResult
#    time :: Float64
#    loss :: Float64
#    iter :: Int64
#    beta :: Vector{Float64}
#end
#
#function IHTResults(
#    time :: Float64, 
#    loss :: Float64, 
#    iter :: Int64,
#    beta :: Vector{Float64})
#    return IHTResult(time, loss, iter, beta)
#end
#
#
#"""
#Returns ω, a constant we need to bound the step size μ to guarantee convergence. 
#"""
#
#function compute_ω!(v::IHTVariable, snpmatrix::Matrix{Float64})
#    #update v.xb
#    A_mul_B!(v.xb, snpmatrix, v.b)
#
#    #calculate ω efficiently (old b0 and xb0 have been copied before calling iht!)
#    return sqeuclidean(v.b, v.b0) / sqeuclidean(v.xb, v.xb0)
#end

"""
This function is needed for testing purposes only. 

Converts a SnpArray to a matrix of float64 using A2 as the minor allele. We want this function 
because SnpArrays.jl uses the less frequent allele in each SNP as the minor allele, while PLINK.jl 
always uses A2 as the minor allele, and it's nice if we could cross-compare the results. 
"""
function use_A2_as_minor_allele(snpmatrix :: SnpArray)
    n, p = size(snpmatrix)
    matrix = zeros(n, p)
    for i in 1:p
        for j in 1:n
            if snpmatrix[j, i] == (0, 0); matrix[j, i] = 0.0; end
            if snpmatrix[j, i] == (0, 1); matrix[j, i] = 1.0; end
            if snpmatrix[j, i] == (1, 1); matrix[j, i] = 2.0; end
            if snpmatrix[j, i] == (1, 0); matrix[j, i] = missing; end
        end
    end
    return matrix
end

"""
This function computes the gradient step v.b = P_k(β + μ∇f(β)), and updates v.idx. 
Recall calling axpy! implies v.b = v.b + μ*v.df, but v.df stores an extra negative sign.
"""
function _iht_gradstep{T <: Float}(
   v  :: IHTVariable{T},
   μ  :: Float64,
   k  :: Int;
)
   BLAS.axpy!(μ, v.df, v.b) # take the gradient step: v.b = b + μ∇f(b) (which is a plus since df stores X(-1*(Y-Xb)))
   project_k!(v.b, k)       # P_k( β - μ∇f(β) ): preserve top k components of b
   _iht_indices(v, k)       # Update idx. (find indices of new beta that are nonzero)

   # If the k'th largest component is not unique, warn the user. 
   sum(v.idx) <= k || warn("More than k components of b is non-zero! Need: VERY DANGEROUS DARK SIDE HACK!")
end

"""
this function updates finds the non-zero index of b, and set v.idx = 1 for those indices. 
"""
function _iht_indices{T <: Float}(
   v :: IHTVariable{T},
   k :: Int
)
   # set v.idx[i] = 1 if v.b[i] != 0 (i.e. find components of beta that are non-zero)
   v.idx .= v.b .!= 0

   # if idx is the 0 vector, v.idx[i] = 1 if i is one of the k largest components
   # of the gradient (stored in v.df), and set other components of idx to 0. 
   if sum(v.idx) == 0
       a = select(v.df, k, by=abs, rev=true) 
       v.idx[abs.(v.df) .>= abs(a)-2*eps()] .= true
       v.gk .= zeros(sum(v.idx))
   end

   return nothing
end

# this function calculates the omega (here a / b) used for determining backtracking
function _iht_omega{T <: Float}(
    v :: IHTVariable{T}
)
    a = sqeuclidean(v.b, v.b0::Vector{T}) :: T
    b = sqeuclidean(v.xb, v.xb0::Vector{T}) :: T
    return a, b
end


# a function for determining whether or not to backtrack
function _iht_backtrack{T <: Float}(
    v       :: IHTVariable{T},
    ot      :: T,
    ob      :: T,
    mu      :: T,
    mu_step :: Int,
    nstep   :: Int
)
    mu*ob > 0.99*ot              &&
    sum(v.idx) != 0              &&
    sum(xor.(v.idx,v.idx0)) != 0 &&
    mu_step < nstep
end
