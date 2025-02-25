"""
    simulate_random_snparray(n::Integer, p::Integer, s::String; mafs::Vector{Float64}, min_ma::Integer)

Creates a random SnpArray in the current directory without missing value, 
where each SNP has ⫺5 (default) minor alleles. 

Note: if supplied minor allele frequency is extremely small, it could take a long time for 
the simulation to generate samples where at least `min_ma` (defaults to 5) are present. 

# Arguments:
- `n`: number of samples
- `p`: number of SNPs
- `s`: name of SnpArray that will be created (memory mapped) in the current directory. To not memory map, use `undef`.

# Optional Arguments:
- `mafs`: vector of desired minor allele freuqencies (uniform(0, 0.5) by default)
- `min_ma`: the minimum number of minor alleles that must be present for each SNP (defaults to 5)
"""
function simulate_random_snparray(n::Int64, p::Int64, s::Union{String, UndefInitializer}; 
                                  mafs::Vector{Float64}=zeros(Float64, p), min_ma::Int = 5)
    
    @assert all(0.0 .<= mafs .<= 0.5) "Minor allele frequencies must be all in the range (0, 0.5)"

    if mafs != zeros(Float64, p)
        return _random_snparray(n, p, s, mafs, min_ma=min_ma)
    end

    #first simulate a random {0, 1, 2} matrix with each SNP drawn from Binomial(2, r[i])
    A1 = BitArray(undef, n, p) 
    A2 = BitArray(undef, n, p) 
    for j in 1:p
        minor_alleles = 0
        maf = 0
        while minor_alleles <= min_ma
            maf = 0.5rand()
            for i in 1:n
                A1[i, j] = rand(Bernoulli(maf))
                A2[i, j] = rand(Bernoulli(maf))
            end
            minor_alleles = sum(view(A1, :, j)) + sum(view(A2, :, j))
        end
        mafs[j] = maf
    end

    #fill the SnpArray with the corresponding x_tmp entry
    return _make_snparray(A1, A2, s)
end

"""
This function requires a vector of minor alleles frequencies to perform simulation. 
It will create a random SnpArray in the current directory without missing value, 
where each SNP has at least 5 minor alleles. 
"""
function _random_snparray(n::Int64, p::Int64, s::Union{String, UndefInitializer}, 
                          mafs::Vector{Float64}; min_ma::Int = 5)
    all(0.0 .<= mafs .<= 0.5) || throw(ArgumentError("vector of minor allele frequencies must be in (0, 0.5)"))
    any(mafs .<= 0.0005) && @warn("Provided minor allele frequencies contain entries smaller than 0.0005, simulation may take long if sample size is small and min_ma = $min_ma is large")

    #first simulate a random {0, 1, 2} matrix with each SNP drawn from Binomial(2, r[i])
    A1 = BitArray(undef, n, p) 
    A2 = BitArray(undef, n, p) 
    for j in 1:p
        minor_alleles = 0
        maf = mafs[j]
        while minor_alleles <= min_ma
            for i in 1:n
                A1[i, j] = rand(Bernoulli(maf))
                A2[i, j] = rand(Bernoulli(maf))
            end
            minor_alleles = sum(view(A1, :, j)) + sum(view(A2, :, j))
        end
    end

    #fill the SnpArray with the corresponding x_tmp entry
    return _make_snparray(A1, A2, s)
end

"""
Make a SnpArray from 2 BitArrays.
"""
function _make_snparray(A1::BitArray, A2::BitArray, s::Union{String, UndefInitializer})
    n, p = size(A1)
    x = SnpArray(s, n, p)
    for i in 1:(n*p)
        c = A1[i] + A2[i]
        if c == 0
            x[i] = 0x00
        elseif c == 1
            x[i] = 0x02
        elseif c == 2
            x[i] = 0x03
        else
            throw(error("matrix shouldn't have missing values!"))
        end
    end
    return x
end

"""
    simulate_correlated_snparray(n, p, s; block_length, hap, prob)

Simulates a SnpArray with correlation. SNPs are divided into blocks where each
adjacent SNP is the same with probability prob. There are no correlation between blocks.

# Arguments:
- `n`: number of samples
- `p`: number of SNPs
- `s`: name of SnpArray that will be created (memory mapped) in the current directory. To not memory map, use `undef`.

# Optional arguments:
- `block_length`: length of each LD block
- `hap`: number of haplotypes to simulate for each block
- `prob`: with probability `prob` an adjacent SNP would be the same. 
"""
function simulate_correlated_snparray(n::Int64, p::Int64, s::Union{String, UndefInitializer}; 
            block_length::Int64=20, hap::Int=20, prob::Float64=0.75)
    
    @assert mod(p, block_length) == 0 "block_length ($block_length) is not divible by p ($p)"
    @assert 0 < prob < 1 "transition probably should be between 0 and 1, got $prob"

    x = SnpArray(s, n, p)
    haplotypes = zeros(hap, block_length)
    snps = zeros(block_length)
    blocks = Int(p / block_length)

    @inbounds for b in 1:blocks

        #create pool of haplotypes for each block
        _sample_haptotypes!(haplotypes, prob)

        for i in 1:n
            #sample 2 haplotypes with replacement from the pool of haplotypes
            row1 = rand(1:hap)
            row2 = rand(1:hap)
            for j in 1:block_length
                snps[j] = haplotypes[row1, j] + haplotypes[row2, j]
            end

            #copy haplotypes into x
            _copy_blocks!(x, i, snps, b, block_length)
        end
    end

    return x
end

function _sample_haptotypes!(haplotypes::Matrix, prob::Float64)
    n, p = size(haplotypes)
    fill!(haplotypes, 0)

    @inbounds for i in 1:n
        cur_row_sum = 0
        while cur_row_sum == 0
            curr = rand(0:1)
            haplotypes[i, 1] = curr
            cur_row_sum += curr
            for j in 2:p
                stay = rand(Bernoulli(prob)) #stay = 1 means retain the current value
                curr = (stay == 1 ? curr : 1 - curr)
                haplotypes[i, j] = curr
                cur_row_sum += curr
            end
        end
    end
end

function _copy_blocks!(x::SnpArray, row, snps, cur_block, block_length)
    #copy sampled snps into SnpArray
    @inbounds for k in 1:length(snps)
        c = snps[k]
        col = (cur_block - 1) * block_length + k
        if c == 0
            x[row, col] = 0x00
        elseif c == 1
            x[row, col] = 0x02
        elseif c == 2
            x[row, col] = 0x03
        else
            throw(error("SNP values should be 0, 1, or 2 but was $c"))
        end
    end
end

"""
    simulate_random_response(x::SnpArray, xbm::SnpBitMatrix, k::Int, d::UnionAll, l::Link)

This function simulates a random response (trait) vector `y` based on provided x, β, distirbution,
and link function. When the distribution is from Poisson, Gamma, or Negative Binomial, we simulate `β ∼ N(0, 0.3)` 
to roughly ensure the mean of response `y` doesn't become too large. For other distributions,
we choose `β ∼ N(0, 1)`. 

# Arguments
- `x`: The SnpArray
- `xbm`: SnpBitMatrix type of your SnpArray
- `k`: the true number of predictors. 
- `d`: The distribution of the simulated trait (note `typeof(d) = UnionAll` but `typeof(d())` is an actual distribution: e.g. Normal)
- `l`: The link function. Input `canonicallink(d())` if you want to use the canonical link of `d`.

# Optional arguments 
- `nn`: The number of success until stopping in negative binomial regression, defaults to 10
- `α`: Shape parameter of the gamma distribution, defaults to 1
"""
function simulate_random_response(x::SnpArray, xbm::SnpBitMatrix, k::Int, 
                                  d::UnionAll, l::Link; nn = 10,
                                  α = 1) where {T <: Float}
    n, p = size(x)
    if (typeof(d) <: NegativeBinomial) || (typeof(d) <: Gamma)
        l == LogLink() || throw(ArgumentError("Distribution $d must use LogLink!"))
    end

    #simulate a random model β from a normal distribution
    true_b = zeros(p)
    if d == Poisson || d == Gamma || d == NegativeBinomial
        true_b[1:k] = rand(Normal(0, 0.3), k)
    else
        true_b[1:k] = randn(k)
    end
    shuffle!(true_b)
    correct_position = findall(x -> x != 0, true_b)

    #simulate phenotypes (e.g. vector y)
    if d == Normal || d == Poisson || d == Bernoulli
        prob = linkinv.(l, xbm * true_b)
        clamp!(prob, -20, 20)
        y = [rand(d(i)) for i in prob]
    elseif d == NegativeBinomial
        μ = linkinv.(l, xbm * true_b)
        clamp!(μ, -20, 20)
        prob = 1 ./ (1 .+ μ ./ nn)
        y = [rand(d(nn, i)) for i in prob] #number of failtures before nn success occurs
    elseif d == Gamma
        μ = linkinv.(l, xbm * true_b)
        β = 1 ./ μ # here β is the rate parameter for gamma distribution
        y = [rand(d(α, i)) for i in β] # α is the shape parameter for gamma
    end
    y = Float64.(y)

    return y, true_b, correct_position
end

"""
    adhoc_add_correlation!(x::SnpArray, ρ::Float64, pos::Int64, location::Vector{Int})

Makes 1 SNP (a column of `x`) correlate with SNPs in `location` with correlation coefficient roughly `ρ`.

# Arguments:
- `x`: the snparray
- `ρ`: correlation coefficient
- `pos`: the position of the target SNP that everything would be correlated to
- `location`: All the SNPs that shall be correlated with the SNP at position `pos` with correlation `ρ`.
"""
function adhoc_add_correlation!(x::SnpArray, ρ::Float64, pos::Int64, location::Vector{Int})
    @assert 0 <= ρ <= 1 "correlation coefficient must be in (0, 1) but was $ρ"

    for loc in location 
        for i in 1:size(x, 1)
            prob = rand(Bernoulli(ρ))
            prob == 1 && (x[i, loc] = x[i, pos]) #make 2nd column the same as 1st ~ρ% of the time
        end
        corr = cor(x[:, loc], x[:, pos])
    end
end

"""
    simulate_rare_variants(mafs::Vector{Float64}, penetrance::Vector{Float64}, cases::Int, controls::Int)

TODO: implement Algrithm 1 of https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3025646/
"""
function simulate_rare_variants(mafs::Vector{Float64}, penetrance::Vector{Float64}, 
                                cases::Int, controls::Int)
    return nothing # not implemented yet
end

"""
    make_bim_fam_files(x::SnpArray, y, name::String)

Creates .bim and .bed files from a SnpArray. 

# Arguments:
- `x`: A SnpArray (i.e. `.bed` file on the disk) for which you wish to create corresponding `.bim` and `.fam` files.
- `name`: string that should match the `.bed` file (Do not include `.bim` or `.fam` extensions in `name`).
- `y`: Trait vector that will go in to the 6th column of `.fam` file. 
"""
function make_bim_fam_files(x::SnpArray, y, name::String)
    ly = length(y)
    n, p = size(x)
    @assert n == ly "dimension mismatch: phenotype data has length $ly but SnpArray has $n samples"

    #create .bim file structure: https://www.cog-genomics.org/plink2/formats#bim
    open(name * ".bim", "w") do f
        for i in 1:p
            write(f, "1 \t $i \t 0 \t 1 \t 1 \t 2 \n")
        end
    end

    #create .fam file structure: https://www.cog-genomics.org/plink2/formats#bim
    open(name * ".fam", "w") do f
        for i in 1:n
            yi = y[i]
            write(f, "$i \t 1 \t 0 \t 0 \t 1 \t $yi \n")
        end
    end
end
