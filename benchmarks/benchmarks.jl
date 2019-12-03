#!/usr/bin/env julia

using PencilFFTs
using PencilFFTs.Pencils

using MPI

using ArgParse
using TimerOutputs

using LinearAlgebra
using Printf
using Profile
using Random

TimerOutputs.enable_debug_timings(PencilFFTs)
TimerOutputs.enable_debug_timings(Pencils)

const PROFILE = false
const PROFILE_OUTPUT = "profile.txt"
const PROFILE_DEPTH = 8

const MEASURE_GATHER = false

const DIMS_DEFAULT = "128,192,64"

const DEV_NULL = @static Sys.iswindows() ? "nul" : "/dev/null"

const SEPARATOR = string("\n\n", "*"^80)

function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        "--dimensions", "-N"
            help = """
            comma-separated list of 3D dataset dimensions.
            A single integer may also be provided."""
            default = DIMS_DEFAULT
        "--repetitions", "-r"
            help = "number of repetitions per benchmark"
            default = 100
        "--full", "-f"
            help = "perform full set of benchmarks (takes a lot more time!)"
            action = :store_true
    end

    parse_args(s)
end

# Slab decomposition
function create_pencils(topo::MPITopology{1}, data_dims, permutation::Val{true};
                        kwargs...)
    pen1 = Pencil(topo, data_dims, (2, ); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(3, ), permute=Val((2, 1, 3)); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(2, ), permute=Val((3, 2, 1)); kwargs...)
    pen1, pen2, pen3
end

function create_pencils(topo::MPITopology{1}, data_dims,
                        permutation::Val{false}; kwargs...)
    pen1 = Pencil(topo, data_dims, (2, ); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(3, ); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(2, ); kwargs...)
    pen1, pen2, pen3
end

# Pencil decomposition
function create_pencils(topo::MPITopology{2}, data_dims, permutation::Val{true};
                        kwargs...)
    pen1 = Pencil(topo, data_dims, (2, 3); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(1, 3), permute=Val((2, 1, 3)); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(1, 2), permute=Val((3, 2, 1)); kwargs...)
    pen1, pen2, pen3
end

function create_pencils(topo::MPITopology{2}, data_dims, permutation::Val{false};
                        kwargs...)
    pen1 = Pencil(topo, data_dims, (2, 3); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(1, 3); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(1, 2); kwargs...)
    pen1, pen2, pen3
end

function benchmark_pencils(comm, proc_dims::Tuple, data_dims::Tuple;
                           iterations=1,
                           with_permutations::Val=Val(true),
                           extra_dims::Tuple=(),
                           transpose_method=TransposeMethods.IsendIrecv(),
                          )
    topo = MPITopology(comm, proc_dims)
    M = length(proc_dims)
    @assert M in (1, 2)

    to = TimerOutput()

    pens = create_pencils(topo, data_dims, with_permutations, timer=to)

    u = map(p -> PencilArray(p, extra_dims), pens)

    myrank = MPI.Comm_rank(comm)
    rng = MersenneTwister(42 + myrank)
    randn!(rng, u[1])
    u[1] .+= 10 * myrank
    u_orig = copy(u[1])

    transpose_m!(a, b) = transpose!(a, b, method=transpose_method)

    # Precompile functions
    transpose_m!(u[2], u[1])
    transpose_m!(u[3], u[2])
    transpose_m!(u[2], u[3])
    transpose_m!(u[1], u[2])
    gather(u[2])

    reset_timer!(to)

    for it = 1:iterations
        transpose_m!(u[2], u[1])
        transpose_m!(u[3], u[2])
        transpose_m!(u[2], u[3])
        transpose_m!(u[1], u[2])
        MEASURE_GATHER && gather(u[2])
    end

    @assert u[1] == u_orig

    if myrank == 0
        println("\n",
            """
            Processes:               $proc_dims
            Data dimensions:         $data_dims $(isempty(extra_dims) ? "" : "× $extra_dims")
            Permutations (1, 2, 3):  $(get_permutation.(pens))
            Transpositions:          1 -> 2 -> 3 -> 2 -> 1
            Method:                  $(transpose_method)
            """)
        println(to, SEPARATOR)
    end

    if PROFILE
        Profile.clear()
        @profile for it = 1:iterations
            transpose_m!(u[2], u[1])
            transpose_m!(u[3], u[2])
            transpose_m!(u[2], u[3])
            transpose_m!(u[1], u[2])
        end
        if myrank == 0
            open(io -> Profile.print(io, maxdepth=PROFILE_DEPTH),
                 PROFILE_OUTPUT, "w")
        end
    end

    nothing
end

function benchmark_rfft(comm, proc_dims::Tuple, data_dims::Tuple;
                        extra_dims=(),
                        iterations=1,
                        transpose_method=TransposeMethods.IsendIrecv(),
                       )
    isroot = MPI.Comm_rank(comm) == 0

    to = TimerOutput()
    plan = PencilFFTPlan(data_dims, Transforms.RFFT(), proc_dims, comm,
                         extra_dims=extra_dims,
                         timer=to, transpose_method=transpose_method)

    isroot && println("\n", plan, "\nMethod: ", plan.transpose_method, "\n")

    u = allocate_input(plan)
    v = allocate_output(plan)
    uprime = similar(u)

    randn!(u)

    # Warm-up
    mul!(v, plan, u)
    ldiv!(uprime, plan, v)

    @assert u ≈ uprime

    reset_timer!(to)

    τ = MPI.Wtime()

    for it = 1:iterations
        mul!(v, plan, u)
        ldiv!(u, plan, v)
    end

    τ = (MPI.Wtime() - τ) / iterations * 1000  # in milliseconds

    events = (to["PencilFFTs mul!"], to["PencilFFTs ldiv!"])
    @assert all(TimerOutputs.ncalls.(events) .== iterations)
    t_avg = sum(TimerOutputs.time.(events)) / iterations / 1e6  # in milliseconds

    if isroot
        @printf "Average time: %.8f ms (MPI_Wtime) over %d repetitions\n" τ iterations
        @printf "              %.8f ms (TimerOutputs)\n\n" t_avg
        println(to, SEPARATOR)
    end

    nothing
end

function parse_dimensions(arg::String) :: Dims{3}
    ints = try
        sp = split(arg, ',')
        parse.(Int, sp)
    catch e
        error("Could not parse dimensions from '$arg'")
    end
    if length(ints) == 1
        N = ints[1]
        (N, N, N)
    elseif length(ints) == 3
        ntuple(n -> ints[n], Val(3))
    else
        error("Incorrect number of dimensions in '$ints'")
    end
end

function main()
    MPI.Init()

    args = parse_commandline()
    dims = parse_dimensions(args["dimensions"])
    iterations = args["repetitions"] :: Int
    full_benchmarks = args["full"] :: Bool

    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    myrank = MPI.Comm_rank(comm)

    if myrank == 0
        @info "Global dimensions: $dims"
        @info "Repetitions:       $iterations"
    end

    # Let MPI_Dims_create choose the decomposition.
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    transpose_methods = (TransposeMethods.IsendIrecv(),
                         TransposeMethods.Alltoallv())

    if full_benchmarks
        extra_dims = ((), (3, ))
        pdims_list = (
                      (Nproc, ),  # slab (1D) decomposition
                      (Nproc, 1),
                      (1, Nproc),
                      proc_dims,
                     )
    else
        extra_dims = ((), )
        pdims_list = (proc_dims, )
    end

    kwargs = (:iterations => iterations, )

    for pdims in pdims_list, edims in extra_dims, method in transpose_methods
        benchmark_rfft(comm, pdims, dims; extra_dims=edims,
                       transpose_method=method, kwargs...)
    end

    if full_benchmarks
        benchmark_pencils(comm, proc_dims, dims; with_permutations=Val(false),
                          kwargs...)
        benchmark_pencils(comm, proc_dims, dims; extra_dims=(2, ), kwargs...)
        benchmark_pencils(comm, proc_dims, dims; extra_dims=(2, ),
                          with_permutations=Val(false), kwargs...)
    end

    MPI.Finalize()
end

main()
