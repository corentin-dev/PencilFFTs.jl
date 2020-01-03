#!/usr/bin/env julia

# See https://jipolanco.github.io/PencilFFTs.jl/dev/examples/gradient/ for
# details.

using BenchmarkTools
using MPI
using PencilFFTs

using AbstractFFTs: fftfreq, rfftfreq
using Printf: @printf
using Random: randn!

const INPUT_DIMS = (64, 32, 64)

const DEV_NULL = @static Sys.iswindows() ? "nul" : "/dev/null"

function generate_wavenumbers_r2c(dims::Dims{3})
    box_size = (2π, 2π, 2π)  # Lx, Ly, Lz
    sample_rate = 2π .* dims ./ box_size

    # In our case (Lx = 2π and Nx even), this gives kx = [0, 1, 2, ..., Nx/2].
    kx = rfftfreq(dims[1], sample_rate[1])

    # In our case (Ly = 2π and Ny even), this gives
    # ky = [0, 1, 2, ..., Ny/2-1, -Ny/2, -Ny/2+1, ..., -1] (and similarly for kz).
    ky = fftfreq(dims[2], sample_rate[2])
    kz = fftfreq(dims[3], sample_rate[3])

    (kx, ky, kz)
end

# Compute and return ∇θ in Fourier space, using global views.
function gradient_global_view!(∇θ_hat::NTuple{3,PencilArray},
                               θ_hat::PencilArray, kvec_global)
    # Generate OffsetArrays that take global indices.
    θ_glob = global_view(θ_hat)
    ∇θ_glob = global_view.(∇θ_hat)

    # Note: in Fourier space, the dimensions are by default permuted to
    # (z, y, x), i.e. the **last** index (the one associated to `z`) varies the
    # fastest, instead of the first index as it is usually in Julia.
    #
    # Unfortunately, when using CartesianIndices, the usual (i, j, k) order is
    # used, instead of the (k, j, i) order that would be optimal here.
    # In other words, looping with CartesianIndices is not very efficient in
    # this specific case.

    @inbounds for I in CartesianIndices(θ_glob)
        i, j, k = Tuple(I)  # global indices

        # Wave number vector associated to current Cartesian index.
        kx = kvec_global[1][i]
        ky = kvec_global[2][j]
        kz = kvec_global[3][k]

        # Performance: compute linear index here, then access arrays using
        # linear index `n` instead of Cartesian index `I`.
        n = LinearIndices(θ_glob)[I]

        u = im * θ_glob[n]

        ∇θ_glob[1][n] = kx * u
        ∇θ_glob[2][n] = ky * u
        ∇θ_glob[3][n] = kz * u
    end

    ∇θ_hat
end

function gradient_global_view_explicit!(∇θ_hat::NTuple{3,PencilArray},
                                        θ_hat::PencilArray, kvec_global)
    # Generate OffsetArrays that take global indices.
    θ_glob = global_view(θ_hat)
    ∇θ_glob = global_view.(∇θ_hat)

    rng = axes(θ_glob)  # (i1:i2, j1:j2, k1:k2)

    # Note: since the dimensions in Fourier space are permuted as (z, y, x), it
    # is faster to loop with `k` as the fastest index.
    @assert get_permutation(θ_hat) === Val((3, 2, 1))

    @inbounds for i in rng[1], j in rng[2], k in rng[3]
        # Wave number vector associated to current Cartesian index.
        kx = kvec_global[1][i]
        ky = kvec_global[2][j]
        kz = kvec_global[3][k]

        u = im * θ_glob[i, j, k]

        ∇θ_glob[1][i, j, k] = kx * u
        ∇θ_glob[2][i, j, k] = ky * u
        ∇θ_glob[3][i, j, k] = kz * u
    end

    ∇θ_hat
end

# Compute and return ∇θ in Fourier space, using local indices.
function gradient_local!(∇θ_hat::NTuple{3,PencilArray}, θ_hat::PencilArray,
                         kvec_global)
    # Get local data range in the global grid.
    rng = range_local(θ_hat)  # = (i1:i2, j1:j2, k1:k2)

    # Local wave numbers: (kx[i1:i2], ky[j1:j2], kz[k1:k2]).
    kvec_local = ntuple(d -> kvec_global[d][rng[d]], Val(3))

    @inbounds for I in CartesianIndices(θ_hat)
        i, j, k = Tuple(I)  # local indices

        # Wave number vector associated to current Cartesian index.
        kx = kvec_local[1][i]
        ky = kvec_local[2][j]
        kz = kvec_local[3][k]

        # Performance: compute linear index here, then access arrays using
        # linear index `n` instead of Cartesian index `I`.
        n = LinearIndices(θ_hat)[I]

        u = im * θ_hat[n]

        ∇θ_hat[1][n] = kx * u
        ∇θ_hat[2][n] = ky * u
        ∇θ_hat[3][n] = kz * u
    end

    ∇θ_hat
end

# Similar to gradient_local!, but avoiding CartesianIndices (faster!).
function gradient_local_linear!(∇θ_hat::NTuple{3,PencilArray},
                                θ_hat::PencilArray, kvec_global)
    # Get local data range in the global grid.
    rng = range_local(θ_hat)  # = (i1:i2, j1:j2, k1:k2)

    # Local wave numbers: (kx[i1:i2], ky[j1:j2], kz[k1:k2]).
    kvec_local = ntuple(d -> kvec_global[d][rng[d]], Val(3))

    # We want to iterate over the arrays in memory order to maximise
    # performance. For this we need to take into account the permutation of
    # indices in the Fourier-transformed arrays. By default, the memory order in
    # Fourier space is (z, y, x) instead of (x, y, z), but this is never assumed
    # below. The wave numbers must be permuted accordingly.
    perm = get_permutation(θ_hat)  # e.g. Val((3, 2, 1))
    kvec_perm = Pencils.permute_indices(kvec_local, perm)  # e.g. (kz, ky, kx)

    # Create wave number iterator.
    kvec_iter = Iterators.product(kvec_perm...)

    # Inverse permutation, to pass from (kz, ky, kx) to (kx, ky, kz).
    iperm = Pencils.inverse_permutation(perm)

    @inbounds for (n, kvec_n) in enumerate(kvec_iter)
        # Apply inverse permutation to the current wave number vector.
        # Note that this permutation has zero cost, since iperm is a
        # compile-time constant!
        # (This can be verified by comparing the performance of this function
        # with the "explicit" variant of `gradient_local_linear`, below.)
        κ = Pencils.permute_indices(kvec_n, iperm)  # = (kx, ky, kz)

        u = im * θ_hat[n]

        # Note that this is very easy to generalise to N dimensions...
        ∇θ_hat[1][n] = κ[1] * u
        ∇θ_hat[2][n] = κ[2] * u
        ∇θ_hat[3][n] = κ[3] * u
    end

    ∇θ_hat
end

# Less generic version of the above, assuming that the permutation is (3, 2, 1).
# It's basically the same but probably easier to understand.
function gradient_local_linear!(∇θ_hat::NTuple{3,PencilArray},
                                θ_hat::PencilArray, kvec_global,
                                perm::Val{(3, 2, 1)},
                               )
    @assert get_permutation(θ_hat) === perm

    # Get local data range in the global grid.
    rng = range_local(θ_hat)  # = (i1:i2, j1:j2, k1:k2)

    # Local wave numbers: (kx[i1:i2], ky[j1:j2], kz[k1:k2]).
    kvec_local = ntuple(d -> kvec_global[d][rng[d]], Val(3))

    # Create wave number iterator in (kz, ky, kx) order, i.e. in the same order
    # as the array data.
    kvec_iter = Iterators.product(kvec_local[3], kvec_local[2], kvec_local[1])

    @inbounds for (n, kvec_n) in enumerate(kvec_iter)
        kz, ky, kx = kvec_n
        u = im * θ_hat[n]
        ∇θ_hat[1][n] = kx * u
        ∇θ_hat[2][n] = ky * u
        ∇θ_hat[3][n] = kz * u
    end

    ∇θ_hat
end

function main()
    MPI.Init()

    # Input data dimensions (Nx × Ny × Nz)
    dims = INPUT_DIMS

    kvec = generate_wavenumbers_r2c(dims)

    # Apply a 3D real-to-complex (r2c) FFT.
    transform = Transforms.RFFT()

    # MPI topology information
    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    rank = MPI.Comm_rank(comm)

    # Disable output on all but one process.
    rank == 0 || redirect_stdout(open(DEV_NULL, "w"))

    # Let MPI_Dims_create choose the decomposition.
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    # Create plan
    plan = PencilFFTPlan(dims, transform, proc_dims, comm)
    println(plan, "\n")

    # Allocate data and initialise field
    θ = allocate_input(plan)
    randn!(θ)

    # Perform distributed FFT
    θ_hat = plan * θ

    # Compute and compare gradients using different methods.
    # Note that these return a tuple of 3 PencilArrays representing a vector
    # field.
    ∇θ_hat_base = allocate_output(plan, Val(3))
    ∇θ_hat_other = similar.(∇θ_hat_base)

    gradient_global_view!(∇θ_hat_base, θ_hat, kvec)

    @printf "%-40s" "gradient_global_view!..."
    @btime gradient_global_view!($∇θ_hat_other, $θ_hat, $kvec)
    @assert all(∇θ_hat_base .≈ ∇θ_hat_other)

    @printf "%-40s" "gradient_global_view_explicit!..."
    @btime gradient_global_view_explicit!($∇θ_hat_other, $θ_hat, $kvec)
    @assert all(∇θ_hat_base .≈ ∇θ_hat_other)

    @printf "%-40s" "gradient_local!..."
    @btime gradient_local!($∇θ_hat_other, $θ_hat, $kvec)         # faster
    @assert all(∇θ_hat_base .≈ ∇θ_hat_other)

    @printf "%-40s" "gradient_local_linear!..."
    @btime gradient_local_linear!($∇θ_hat_other, $θ_hat, $kvec)  # fastest
    @assert all(∇θ_hat_base .≈ ∇θ_hat_other)

    # Test the "explicit" variant of `gradient_local_linear`
    let perm = get_permutation(θ_hat)  # permutation in Fourier space
        gradient_local_linear!(∇θ_hat_other, θ_hat, kvec, perm)
        @assert all(∇θ_hat_base .≈ ∇θ_hat_other)

        # Same timings as generic version of `gradient_local_linear`!
        @printf "%-40s" "gradient_local_linear! (explicit)..."
        @btime gradient_local_linear!($∇θ_hat_other, $θ_hat, $kvec, $perm)
    end

    # Get gradient in physical space.
    ∇θ = plan \ ∇θ_hat_base

    MPI.Finalize()
end

main()
