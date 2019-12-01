#!/usr/bin/env julia

using PencilFFTs.Pencils

using MPI

using BenchmarkTools
using InteractiveUtils
using LinearAlgebra
using Random
using Test

const BENCHMARK_ARRAYS = false
const DEV_NULL = @static Sys.iswindows() ? "nul" : "/dev/null"


Indexation(::Type{IndexLinear}) = LinearIndices
Indexation(::Type{IndexCartesian}) = CartesianIndices

function test_fill!(::Type{T}, u, val) where {T <: IndexStyle}
    for I in Indexation(T)(u)
        @inbounds u[I] = val
    end
    u
end

function test_array_wrappers(p::Pencil)
    T = eltype(p)
    u = PencilArray(p)
    perm = get_permutation(p)
    permute = Pencils.permute_indices

    @test eltype(u) === eltype(u.data) === T
    @test length.(axes(u)) === size(u)

    if BENCHMARK_ARRAYS
        for S in (IndexLinear, IndexCartesian)
            @info "Filling arrays using $S (Array, PencilArray)" get_permutation(p)
            @time for v in (parent(u), u)
                val = 3 * oneunit(eltype(v))
                @btime test_fill!($S, $v, $val)
            end
        end
    end

    let v = similar(u)
        @test typeof(v) === typeof(u)
        @test size(v) === size(u) === size_local(p, permute=false)

        vp = parent(v)
        randn!(vp)
        I = size(v) .>> 1  # non-permuted indices
        J = Pencils._permute_indices(v, I...)
        @test v[I...] == vp[J...]
    end

    let psize = size_local(p)
        a = zeros(T, psize)
        u = PencilArray(p, a)
        @test u.data === a
        @test IndexStyle(typeof(u)) === IndexStyle(typeof(a)) === IndexLinear()

        b = zeros(T, psize .+ 2)
        @test_throws DimensionMismatch PencilArray(p, b)
        @test_throws DimensionMismatch PencilArray(p, zeros(T, 3, psize...))

        # This is allowed.
        w = PencilArray(p, zeros(T, psize..., 3))
        @test size_global(w) === (size_global(p)..., 3)

        @inferred PencilArray(p, zeros(T, psize..., 3))
        @inferred size_global(w)
    end

    nothing
end

function compare_distributed_arrays(u_local::PencilArray, v_local::PencilArray)
    comm = get_comm(u_local)
    root = 0
    myrank = MPI.Comm_rank(comm)

    u = gather(u_local, root)
    v = gather(v_local, root)

    same = Ref(false)
    if u !== nothing && v !== nothing
        @assert myrank == root
        same[] = u == v
    end
    MPI.Bcast!(same, length(same), root, comm)

    same[]
end

function main()
    MPI.Init()

    Nxyz = (16, 21, 41)
    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    myrank = MPI.Comm_rank(comm)
    root = 0

    myrank == root || redirect_stdout(open(DEV_NULL, "w"))

    rng = MersenneTwister(42 + myrank)

    # Let MPI_Dims_create choose the values of (P1, P2).
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    topo = MPITopology(comm, proc_dims)

    pen1 = Pencil(topo, Nxyz, (2, 3))
    pen2 = Pencil(pen1, decomp_dims=(1, 3), permute=Val((2, 3, 1)))
    pen3 = Pencil(pen2, decomp_dims=(1, 2), permute=Val((3, 2, 1)))

    # Note: the permutation of pen2 was chosen such that the inverse permutation
    # is different.
    @assert pen2.perm !== Pencils.inverse_permutation(pen2.perm)

    @testset "Pencil constructor checks" begin
        # Too many decomposed directions
        @test_throws ArgumentError Pencil(
            MPITopology(comm, (Nproc, 1, 1)), Nxyz, (1, 2, 3))

        # Invalid permutations
        @test_throws TypeError Pencil(
            topo, Nxyz, (1, 2), permute=(2, 3, 1))
        @test_throws ArgumentError Pencil(
            topo, Nxyz, (1, 2), permute=Val((0, 3, 15)))

        # Decomposed dimensions may not be repeated.
        @test_throws ArgumentError Pencil(topo, Nxyz, (2, 2))

        # Decomposed dimensions must be in 1:N = 1:3.
        @test_throws ArgumentError Pencil(topo, Nxyz, (1, 4))
        @test_throws ArgumentError Pencil(topo, Nxyz, (0, 2))
    end

    @testset "PencilArray" begin
        test_array_wrappers(pen1)
        test_array_wrappers(Pencil(pen2, Float32))
        test_array_wrappers(Pencil(pen3, Float64))
    end

    @testset "auxiliary functions" begin
        @test Pencils.complete_dims(Val(5), (2, 3), (42, 12)) ===
            (1, 42, 12, 1, 1)
        @test get_permutation(pen1) === nothing
        @test get_permutation(pen2) === Val((2, 3, 1))

        @test Pencils.relative_permutation(pen2, pen3) === Val((2, 1, 3))

        let a = Val((2, 1, 3)), b = Val((3, 2, 1))
            @test Pencils.permute_indices((:a, :b, :c), Val((2, 3, 1))) ===
                (:b, :c, :a)
            a2b = Pencils.relative_permutation(a, b)
            @test Pencils.permute_indices(a, a2b) === b

            x = Val((3, 1, 2))
            x2nothing = Pencils.relative_permutation(x, nothing)
            @test Pencils.permute_indices(x, x2nothing) === Val((1, 2, 3))
        end
    end

    transpose_methods = (TransposeMethods.IsendIrecv(),
                         TransposeMethods.Alltoallv())

    @testset "transpose! $method" for method in transpose_methods
        u1 = PencilArray(pen1)
        u2 = PencilArray(pen2)
        u3 = PencilArray(pen3)

        # Set initial random data.
        randn!(rng, u1)
        u1 .+= 10 * myrank
        u1_orig = copy(u1)

        # Direct u1 -> u3 transposition is not possible!
        @test_throws ArgumentError transpose!(u3, u1)

        # Transpose back and forth between different pencil configurations
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)

        transpose!(u3, u2)
        @test compare_distributed_arrays(u2, u3)

        transpose!(u2, u3)
        @test compare_distributed_arrays(u2, u3)

        transpose!(u1, u2)
        @test compare_distributed_arrays(u1, u2)

        @test u1_orig == u1

        # Test transpositions without permutations.
        let pen2 = Pencil(pen1, decomp_dims=(1, 3))
            u2 = PencilArray(pen2)
            transpose!(u2, u1)
            @test compare_distributed_arrays(u1, u2)
        end

    end

    # Test arrays with extra dimensions.
    @testset "extra dimensions" begin
        u1 = PencilArray(pen1, (3, 4))
        u2 = PencilArray(pen2, (3, 4))
        u3 = PencilArray(pen3, (3, 4))
        randn!(rng, u1)
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)
        transpose!(u3, u2)
        @test compare_distributed_arrays(u2, u3)

        @inferred global_view(u1)
    end

    # Test slab (1D) decomposition.
    @testset "1D decomposition" begin
        topo = MPITopology(comm, (Nproc, ))
        pen1 = Pencil(topo, Nxyz, (1, ))
        pen2 = Pencil(pen1, decomp_dims=(2, ))
        u1 = PencilArray(pen1)
        u2 = PencilArray(pen2)
        randn!(rng, u1)
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)

        # Same decomposed dimension as pen2, but different permutation.
        let pen = Pencil(pen2, decomp_dims=(2, ), permute=Val((3, 2, 1)))
            v = PencilArray(pen)
            transpose!(v, u2)
            @test compare_distributed_arrays(u1, v)
        end

        # Test transposition between two identical configurations.
        transpose!(u2, u2)
        @test compare_distributed_arrays(u1, u2)

        let v = similar(u2)
            @test u2.pencil === v.pencil
            transpose!(v, u2)
            @test compare_distributed_arrays(u1, v)
        end
    end

    begin
        MPITopologies = Pencils.MPITopologies
        periods = zeros(Int, length(proc_dims))
        comm_cart = MPI.Cart_create(comm, collect(proc_dims), periods, false)
        @inferred MPITopologies.create_subcomms(Val(2), comm_cart)
        @inferred Pencils.MPITopology{2}(comm_cart)
        @inferred MPITopologies.get_cart_ranks_subcomm(pen1.topology.subcomms[1])

        @inferred Pencils.to_local(pen2, (1, 2, 3))
        @inferred Pencils.to_local(pen2, (1:2, 1:2, 1:2))

        @inferred Pencils.size_local(pen2)

        @inferred PencilArray(pen2)
        @inferred PencilArray(pen2, (3, 4))

        @inferred Pencils.permute_indices(Nxyz, Val((2, 3, 1)))
        @inferred Pencils.relative_permutation(Val((1, 2, 3)), Val((2, 3, 1)))
        @inferred Pencils.relative_permutation(Val((1, 2, 3)), nothing)

        u1 = PencilArray(pen1)
        u2 = PencilArray(pen2)

        @inferred Nothing gather(u2)
        @inferred transpose!(u2, u1)
        @inferred Pencils.transpose_impl!(1, u2, u1)
        @inferred Pencils._get_remote_indices(1, (2, 3), 8)
    end

    MPI.Finalize()
end

main()
