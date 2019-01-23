module HMM

using Distributions
using Random
using Combinatorics
using LinearAlgebra

struct Digraph
    from::Array{Int}
    to::Array{Int}
end

Base.copy( g::Digraph ) = Digraph( copy( g.from ), copy( g.to ) )

function addedge( g::Digraph, from::Int, to::Int )
    push!( g.from, from )
    push!( g.to, to )
end

fullyconnected( n::Int ) = Digraph( vcat( [collect(1:n) for i in 1:n]... ), vcat( [fill(i,n) for i in 1:n]... ) )

mutable struct GaussianHMM{Calc <: Real, Out <: Real}
    graph::Digraph
    initialprobabilities::Vector{Calc}
    transitionprobabilities::Matrix{Calc}
    means::Vector{Out}
    stds::Vector{Out}
    scratch::Dict{Symbol,Any}
end

GaussianHMM( g::Digraph, pi::Vector{Calc}, a::Matrix{Calc}, mu::Vector{Out}, sigma::Vector{Out};
             scratch::Dict{Symbol,Any} = Dict{Symbol,Any}() )  where {Calc, Out} =
                 GaussianHMM{Calc, Out}( g, pi, a, mu, sigma, scratch )

Base.copy( hmm::GaussianHMM ) =
    GaussianHMM( copy( hmm.graph ), copy( hmm.initialprobabilities ), copy( hmm.transitionprobabilities ),
                 copy( hmm.means ), copy( hmm.stds ), copy( hmm.scratch ) )

function randomhmm( g::Digraph; calc::DataType = Float64, out::DataType = Float64, seed::Int = 1 )
    Random.seed!( seed )
    
    numstates = max( maximum( g.from ), maximum( g.to ) )
    initialprobabilities = Vector{calc}(rand( numstates ))
    initialprobabilities ./= sum( initialprobabilities )
    transitionprobabilities = Matrix{calc}(rand( numstates, numstates ))
    transitionprobabilities ./= sum( transitionprobabilities, dims=2 )
    means = Vector{out}(randn( numstates ))
    stds = Vector{out}(randn( numstates ).^2)
    scratch = Dict{Symbol,Any}()
    scratch[:seed] = seed
    return GaussianHMM( g, initialprobabilities, transitionprobabilities, means, stds, scratch=scratch )
end

function Base.rand( hmm::GaussianHMM, n::Int )
    cdfs = [ cumsum( hmm.transitionprobabilities[i,:] ) for i in 1:length(hmm.initialprobabilities) ]
    
    state = searchsorted( cumsum( hmm.initialprobabilities ), rand() ).start
    observations = [rand( Normal(hmm.means[state], hmm.stds[state]) )]
    
    for t = 2:n
        state = searchsorted( cdfs[state], rand() ).start
        push!( observations, rand( Normal(hmm.means[state], hmm.stds[state]) ) )
    end
    return observations
end

struct Interval{T<:Number}
    lo::T
    hi::T
end

function clearscratch( hmm::GaussianHMM )
    delete!( hmm.scratch, :alpha )
    delete!( hmm.scratch, :beta )
    delete!( hmm.scratch, :gamma )
    delete!( hmm.scratch, :xi )
    delete!( hmm.scratch, :b )
    delete!( hmm.scratch, :likelihood )
end

function write( io::IO, hmm::GaussianHMM )
    write( io, hmm.graph )
    write( io, hmm.initialprobabilities )
    write( io, hmm.transitionprobabilities )
    write( io, hmm.means )
    write( io, hmm.stds )
    write( io, hmm.scratch[:y] )
end

function setobservations( hmm::GaussianHMM, y::Union{Vector{U},Vector{Interval{U}}} ) where {U <: Real}
    clearscratch( hmm )
    hmm.scratch[:y] = y
end

function observations( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :y )
        error( "Need to set observations in order to perform calculation" )
    end
    return hmm.scratch[:y]
end

probability( d::Distribution, x::N ) where {N <: Number} = pdf( d, x )
   
probability( d::Distribution, i::Interval ) = cdf( d, i.hi ) - cdf( d, i.lo )

function probability( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :b )
        y = observations( hmm )
        hmm.scratch[:b] =
            [[probability( Normal( hmm.means[i], hmm.stds[i] ), y[t] ) for i in 1:length(hmm.means)] for t in 1:length(y)]
    end
    return hmm.scratch[:b]
end

function stationary( hmm::GaussianHMM )
    P = Matrix{Float64}( hmm.transitionprobabilities )
    N = length(hmm.initialprobabilities)
    I = eye(N)
    P -= I
    P[:,1] = ones(N)
    return I[1,:]'*pinv(P)
end

function forwardprobabilities( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :alpha )
        y = observations( hmm )
        N = length(hmm.initialprobabilities)
        b = probability( hmm )
        probabilities = [hmm.initialprobabilities .* b[1]]
        for i = 2:length(y)
            joint = hmm.transitionprobabilities' * probabilities[end] .* b[i]
            push!( probabilities, joint )
        end
        hmm.scratch[:alpha] = probabilities
    end
    return hmm.scratch[:alpha]
end

function backwardprobabilities( hmm::GaussianHMM{Calc, Out} ) where {Calc, Out}
    if !haskey( hmm.scratch, :beta )
        y = observations( hmm )
        N = length(hmm.initialprobabilities)
        probabilities = [ones(Calc,length(hmm.initialprobabilities))]
        b = probability( hmm )
        for i = length(y):-1:2
            joint = hmm.transitionprobabilities * (probabilities[end] .* b[i])
            push!( probabilities, joint )
        end
        hmm.scratch[:beta] = reverse(probabilities)
    end
    return hmm.scratch[:beta]
end

function likelihood( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :likelihood )
        alpha = forwardprobabilities( hmm )        
        hmm.scratch[:likelihood] = sum(alpha[end])
    end
    return hmm.scratch[:likelihood]
end

function conditionalstateprobabilities( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :gamma )
        y = observations( hmm )
        T = length(y)
        alpha = forwardprobabilities( hmm )
        beta = backwardprobabilities( hmm )
        proby = likelihood( hmm )
        hmm.scratch[:gamma] = [alpha[i][j] * beta[i][j]/proby for i in 1:T, j in 1:length(alpha[1])]
    end
    return hmm.scratch[:gamma]
end

function conditionaljointstateprobabilities( hmm::GaussianHMM )
    if !haskey( hmm.scratch, :xi )
        y = observations( hmm )
        T = length(y)
        alpha = forwardprobabilities( hmm )
        beta = backwardprobabilities( hmm )
        proby = likelihood( hmm )
        b = probability( hmm )
        hmm.scratch[:xi] = [hmm.transitionprobabilities.*(alpha[i]*(beta[i+1].*b[i+1])')/proby for i in 1:T-1]
    end
    return hmm.scratch[:xi]
end

function emstep( hmm::GaussianHMM, nexthmm::GaussianHMM; usestationary::Bool = false )
    y = observations( hmm )
    T = length(y)
    gamma = conditionalstateprobabilities( hmm )
    occupation = sum(gamma[1:end-1,:],dims=1)
    xi = conditionaljointstateprobabilities( hmm )

    nexthmm.transitionprobabilities = sum(xi)./occupation'
    if usestationary
        nexthmm.initialprobabilities = stationary( nexthmm )
    else
        nexthmm.initialprobabilities = gamma[1,:]
    end
    nexthmm.means = sum([gamma[i,:]*y[i] for i in 1:T])./vec(occupation)
    nexthmm.stds = sqrt.(sum([gamma[i,:].*(y[i] .- hmm.means).^2 for i in 1:T])./vec(occupation))

    clearscratch( nexthmm )
end

function em( hmm::GaussianHMM{Calc, Out};
             epsilon::Float64 = 0.0,
             debug::Int = 0,
             maxiterations::Float64 = Inf,
             usestationary::Bool = false ) where {Calc, Out}
    t0 = Base.time()
    nexthmm = randomhmm( hmm.graph, calc=Calc )
    setobservations( nexthmm, observations( hmm ) )
    hmms = [hmm, nexthmm]
    oldlikelihood = zero(Calc)
    newlikelihood = likelihood( hmm )
    done = false
    i = 1

    iterations = 1
    while !done
        if debug >= 2
            println( "Likelihood = $newlikelihood" )
        end
        emstep( hmms[i], hmms[3-i], usestationary=usestationary )
        oldlikelihood = newlikelihood
        done = any(isnan.(hmms[3-i].initialprobabilities)) || any(isnan.(hmms[3-i].transitionprobabilities)) ||
            any(isnan.(hmms[3-i].means)) || any(isnan.(hmms[3-i].stds)) || any(hmms[3-i].stds.<=0) ||
            iterations >= maxiterations
        if !done
            newlikelihood = likelihood( hmms[3-i] )
            done = newlikelihood / oldlikelihood - 1 <= epsilon
        end
        i = 3-i
        iterations += 1
    end

    hmm.initialprobabilities = hmms[3-i].initialprobabilities
    hmm.transitionprobabilities = hmms[3-i].transitionprobabilities
    hmm.means = hmms[3-i].means
    hmm.stds = hmms[3-i].stds
    hmm.scratch = hmms[3-i].scratch
    
    hmm.scratch[:iterations] = iterations
    hmm.scratch[:time] = Base.time() - t0
    
    if debug >= 1
        println( "Final likelihood = $oldlikelihood; iterations = $iterations, time = $(hmm.scratch[:time])" )
        flush(stdout)
    end
end

time( hmm::GaussianHMM ) = hmm.scratch[:time]

iterations( hmm::GaussianHMM ) = hmm.scratch[:iterations]

function permutederror( hmm1::GaussianHMM, hmm2::GaussianHMM )
    # use transition matrix to find best permutation; apply to means and stds
    n = length(hmm1.initialprobabilities)
    @assert( n == length(hmm2.initialprobabilities) )
    minerror = Inf
    minperm = nothing
    tp1 = convert( Matrix{Float64}, hmm1.transitionprobabilities )
    tp2 = convert( Matrix{Float64}, hmm2.transitionprobabilities )
    for perm in permutations(1:n)
        error = norm( tp1[perm, perm] - tp2, Inf )
        if error < minerror
            minerror = error
            minperm = perm
        end
    end
    meanerror = norm( hmm1.means[minperm] - hmm2.means, Inf )
    stderror = norm( hmm1.stds[minperm] - hmm2.stds, Inf )
    return (transitionprobabilities=minerror, means=meanerror, stds=stderror)
end

end # module
