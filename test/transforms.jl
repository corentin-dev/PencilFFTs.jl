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

function test_transform_types(size_in)
    transforms = (Transforms.RFFT(), Transforms.FFT(), Transforms.FFT())
    fft_params = PencilFFTs.GlobalFFTParams(size_in, transforms)

    @test fft_params isa PencilFFTs.GlobalFFTParams{Float64, 3,
                                                    typeof(transforms)}
    @test inv(Transforms.RFFT()) === Transforms.BRFFT()
    @test inv(Transforms.IRFFT()) === Transforms.RFFT()

    transforms_inv = inv.(transforms)
    size_out = Transforms.length_output.(transforms, size_in)

    @test transforms_inv ===
        (Transforms.BRFFT(), Transforms.BFFT(), Transforms.BFFT())
    @test size_out === (size_in[1] ÷ 2 + 1, size_in[2:end]...)
    @test Transforms.length_output.(transforms_inv, size_out) === size_in

    @test PencilFFTs.input_data_type(fft_params) === Float64

    nothing
end

function test_transforms(comm, proc_dims, size_in)
    root = 0
    myrank = MPI.Comm_rank(comm)
    myrank == root || redirect_stdout(open(DEV_NULL, "w"))

    pairs = (Transforms.RFFT() => FFTW.plan_rfft,
             Transforms.FFT() => FFTW.plan_fft,
             Transforms.BFFT() => FFTW.plan_bfft,
            )

    @testset "$p ($T)" for p in pairs, T in (Float32, Float64)
        @inferred PencilFFTPlan(size_in, p.first, proc_dims, comm, T)
        plan = PencilFFTPlan(size_in, p.first, proc_dims, comm, T) 
        fftw_planner = p.second

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
            println("\n", plan, "\n")

            p = fftw_planner(ug)

            vg_serial = p * ug
            mul!(vg_serial, p, ug)
            @test vg ≈ vg_serial

            uprime_serial = similar(ug)
            # For some reason, this also modifies vg_serial...
            ldiv!(uprime_serial, p, vg_serial)
            @test ug ≈ uprime_serial
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

    test_transforms(comm, proc_dims, size_in)

    @testset "Transform types" begin
        let transforms = (Transforms.RFFT(), Transforms.FFT(), Transforms.FFT())
            @inferred PencilFFTPlan(size_in, transforms, proc_dims, comm)
            @inferred PencilFFTs.input_data_type(Float64, transforms...)

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
    end

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
