#!/usr/bin/env julia

using PencilFFTs

import FFTW
using MPI

using InteractiveUtils
using LinearAlgebra
using Random
using Test
using TimerOutputs

const DATA_DIMS = (64, 40, 32)

const DEV_NULL = @static Sys.iswindows() ? "nul" : "/dev/null"

const TEST_KINDS_R2R = (
    FFTW.REDFT00,
    FFTW.REDFT01,
    FFTW.REDFT10,
    FFTW.REDFT11,
    FFTW.RODFT00,
    FFTW.RODFT01,
    FFTW.RODFT10,
    FFTW.RODFT11,
)

function test_transform_types(size_in)
    transforms = (Transforms.RFFT(), Transforms.FFT(), Transforms.FFT())
    fft_params = PencilFFTs.GlobalFFTParams(size_in, transforms)

    @test fft_params isa PencilFFTs.GlobalFFTParams{Float64, 3,
                                                    typeof(transforms)}
    @test binv(Transforms.RFFT()) === Transforms.BRFFT()

    transforms_binv = binv.(transforms)
    size_out = Transforms.length_output.(transforms, size_in)

    @test transforms_binv ===
        (Transforms.BRFFT(), Transforms.BFFT(), Transforms.BFFT())
    @test size_out === (size_in[1] ÷ 2 + 1, size_in[2:end]...)
    @test Transforms.length_output.(transforms_binv, size_out) === size_in

    @test PencilFFTs.input_data_type(fft_params) === Float64

    # Test type stability of generated plan_r2r (which, as defined in FFTW.jl,
    # is type unstable!). See comments of `plan` in src/Transforms/r2r.jl.
    let A = zeros(4, 6, 8)
        kind = FFTW.REDFT00
        transform = Transforms.R2R{kind}()
        @inferred Transforms.plan(transform, A, 2)
        @inferred Transforms.plan(transform, A, (1, 3))
        @inferred Transforms.plan(transform, A)

        # This will fail because length(2:3) is not known by the compiler.
        @test_throws ErrorException @inferred Transforms.plan(transform, A, 2:3)
    end

    nothing
end

function test_transforms(comm, proc_dims, size_in)
    root = 0
    myrank = MPI.Comm_rank(comm)
    myrank == root || redirect_stdout(open(DEV_NULL, "w"))

    pair_r2r(tr::Transforms.R2R) =
        tr => (x -> FFTW.plan_r2r(x, Transforms.kind(tr)))
    pairs_r2r = (pair_r2r(Transforms.R2R{k}()) for k in TEST_KINDS_R2R)

    pairs = (
             Transforms.BRFFT() => FFTW.plan_brfft,
             Transforms.FFT() => FFTW.plan_fft,
             Transforms.RFFT() => FFTW.plan_rfft,
             Transforms.BFFT() => FFTW.plan_bfft,
             pairs_r2r...,
             (Transforms.NoTransform(), Transforms.RFFT(), Transforms.FFT())
                => (x -> FFTW.plan_rfft(x, 2:3)),
             (Transforms.FFT(), Transforms.NoTransform(), Transforms.FFT())
                => (x -> FFTW.plan_fft(x, (1, 3))),
             (Transforms.FFT(), Transforms.NoTransform(), Transforms.NoTransform())
                => (x -> FFTW.plan_fft(x, 1)),
            )

    @testset "$(p.first) -- $T" for p in pairs, T in (Float32, Float64)
        if p.first === Transforms.BRFFT()
            # FIXME...
            # In this case, I need to change the order of the transforms
            # (from right to left)
            @test_broken PencilFFTPlan(size_in, p.first, proc_dims, comm, T)
            continue
        end

        @inferred PencilFFTPlan(size_in, p.first, proc_dims, comm, T)
        plan = PencilFFTPlan(size_in, p.first, proc_dims, comm, T)
        fftw_planner = p.second

        println("\n", "-"^60, "\n\n", plan, "\n")

        @inferred allocate_input(plan)
        @inferred allocate_output(plan)
        u = allocate_input(plan)
        v = allocate_output(plan)

        randn!(u)

        mul!(v, plan, u)
        uprime = similar(u)
        ldiv!(uprime, plan, v)

        @test u ≈ uprime

        # Compare result with serial FFT.
        same = Ref(false)
        ug = gather(u, root)
        vg = gather(v, root)

        if ug !== nothing && vg !== nothing
            p = fftw_planner(ug)

            vg_serial = p * ug
            mul!(vg_serial, p, ug)
            @test vg ≈ vg_serial
        end

        MPI.Barrier(comm)
    end

    redirect_stdout(stdout)  # undo redirection

    nothing
end

function test_pencil_plans(size_in::Tuple)
    @assert length(size_in) >= 3
    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)

    # Let MPI_Dims_create choose the decomposition.
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    @inferred PencilFFTPlan(size_in, Transforms.RFFT(), proc_dims, comm, Float64)

    @testset "Transform types" begin
        let transforms = (Transforms.RFFT(), Transforms.FFT(), Transforms.FFT())
            @inferred PencilFFTPlan(size_in, transforms, proc_dims, comm)
            @inferred PencilFFTs.input_data_type(Float64, transforms...)
        end

        let transforms = (Transforms.NoTransform(), Transforms.FFT())
            @test PencilFFTs.input_data_type(Float32, transforms...) ===
                ComplexF32
            @inferred PencilFFTs.input_data_type(Float32, transforms...)
        end

        let transforms = (Transforms.NoTransform(), Transforms.NoTransform())
            @test PencilFFTs.input_data_type(Float32, transforms...) ===
                Nothing
            @inferred PencilFFTs.input_data_type(Float32, transforms...)
        end
    end

    test_transforms(comm, proc_dims, size_in)

    nothing
end

function main()
    MPI.Init()

    size_in = DATA_DIMS
    test_transform_types(size_in)
    test_pencil_plans(size_in)

    MPI.Finalize()
end

main()
