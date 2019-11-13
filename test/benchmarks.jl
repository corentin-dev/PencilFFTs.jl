#!/usr/bin/env julia

using PencilFFTs.Pencils

import Base: show

using MPI

using InteractiveUtils
using Profile
using Random
using Test
using TimerOutputs

TimerOutputs.enable_debug_timings(Pencils)

const PROFILE = false
const PROFILE_OUTPUT = "profile.txt"
const PROFILE_DEPTH = 8

const MEASURE_GATHER = false

const DIMS = (128, 192, 64)
const ITERATIONS = 20

# Slab decomposition
function create_pencils(topo::MPITopology{1}, data_dims, permutation::Val{true};
                        kwargs...)
    pen1 = Pencil(topo, data_dims, (2, ); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(3, ), permute=(2, 1, 3); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(2, ), permute=(3, 2, 1); kwargs...)
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
    pen2 = Pencil(pen1, decomp_dims=(1, 3), permute=(2, 1, 3); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(1, 2), permute=(3, 2, 1); kwargs...)
    pen1, pen2, pen3
end

function create_pencils(topo::MPITopology{2}, data_dims, permutation::Val{false};
                        kwargs...)
    pen1 = Pencil(topo, data_dims, (2, 3); kwargs...)
    pen2 = Pencil(pen1, decomp_dims=(1, 3); kwargs...)
    pen3 = Pencil(pen2, decomp_dims=(1, 2); kwargs...)
    pen1, pen2, pen3
end

function benchmark_decomp(comm, proc_dims::Tuple, data_dims::Tuple;
                          iterations=ITERATIONS,
                          with_permutations::Val=Val(true),
                          extra_dims::Tuple=(),
                          transpose_method=TransposeMethods.IsendIrecv(),
                         )
    topo = MPITopology(comm, proc_dims)
    M = length(proc_dims)
    @assert M in (1, 2)

    to = TimerOutput()

    pens = create_pencils(topo, data_dims, with_permutations, timer=to)

    u = PencilArray.(pens, extra_dims...)

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

    @test u[1] == u_orig

    if myrank == 0
        print(
            """
            Processes:               $proc_dims
            Data dimensions:         $data_dims $(isempty(extra_dims) ? "" : "× $extra_dims")
            Permutations (1, 2, 3):  $(get_permutation.(pens))
            Transpositions:          1 -> 2 -> 3 -> 2 -> 1
            Method:                  $(transpose_method)
            """)
        println(to)
        println()
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

function main()
    MPI.Init()

    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    myrank = MPI.Comm_rank(comm)

    # Let MPI_Dims_create choose the decomposition.
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    pdims_list = (
                  (Nproc, ),  # slab (1D) decomposition
                  (Nproc, 1),
                  (1, Nproc),
                  proc_dims,
                 )

    transpose_methods = (TransposeMethods.IsendIrecv(),
                         TransposeMethods.Alltoallv())

    for pdims in pdims_list, method in transpose_methods
        benchmark_decomp(comm, pdims, DIMS, transpose_method=method)
    end

    benchmark_decomp(comm, proc_dims, DIMS, with_permutations=Val(false))
    benchmark_decomp(comm, proc_dims, DIMS, extra_dims=(2, ),
                     iterations=ITERATIONS >> 1)
    benchmark_decomp(comm, proc_dims, DIMS, extra_dims=(2, ),
                     iterations=ITERATIONS >> 1, with_permutations=Val(false))

    MPI.Finalize()
end

main()
