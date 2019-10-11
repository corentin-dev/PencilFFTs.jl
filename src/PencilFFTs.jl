module PencilFFTs

export PencilPlan
export input_range, output_range, size_global
export allocate_input, allocate_output

import Base: show, eltype

using MPI

# Type definitions
const FFTReal = Union{Float32,Float64}  # same as FFTW.fftwReal
const ArrayRegion = NTuple{3,UnitRange{Int}}

"""
    PencilPlan([T=Float64], comm::MPI.Comm, P1, P2, Nx, Ny, Nz)

Create "plan" for pencil-decomposed FFTs.

Data is decomposed among MPI processes in communicator `comm` (usually
`MPI_COMM_WORLD`), with `P1` and `P2` the number of processes in each of the
decomposed directions.

The real-space dimensions of the data to be transformed are `Nx`, `Ny` and `Nz`.
"""
struct PencilPlan{T<:FFTReal}
    # MPI communicator with Cartesian topology (describing the x-pencil layout).
    comm_cart_x :: MPI.Comm

    # Number of processes in the two decomposed directions.
    #   x-pencil: (P1, P2) = (Py, Pz)
    #   y-pencil: (P1, P2) = (Px, Pz)
    #   z-pencil: (P1, P2) = (Px, Py)
    P1 :: Int
    P2 :: Int

    # Global dimensions of real data (Nx, Ny, Nz).
    size_global :: Dims{3}

    # Local range of real data in x-pencil configuration.
    rrange_x :: ArrayRegion

    # Local range of complex data, for each pencil configuration.
    crange_x :: ArrayRegion
    crange_y :: ArrayRegion
    crange_z :: ArrayRegion

    function PencilPlan(::Type{T}, comm::MPI.Comm, P1, P2, Nx, Ny, Nz) where {T <: FFTReal}
        Nproc = MPI.Comm_size(comm)

        if P1 * P2 != Nproc
            error("Decomposition with (P1, P2) = ($P1, $P2) not compatible with communicator size $Nproc.")
        end

        Nxyz = (Nx, Ny, Nz)

        if any(isodd.(Nxyz))
            # TODO Maybe this can be relaxed?
            error("Dimensions (Nx, Ny, Nz) must be even.")
        end

        # Create Cartesian communicators.
        comm_cart = let dims = [1, P1, P2]
            periods = [1, 1, 1]  # periodicity info is useful for MPI.Cart_shift
            reorder = true
            MPI.Cart_create(comm, dims, periods, reorder)
        end

        # Local range of real data in x-pencil setting.
        rrange_x = _get_data_range_x(comm_cart, Nxyz, (P1, P2))

        Nxyz_c = (_complex_size_x(Nx), Ny, Nz)  # global dimensions of complex data

        # Local ranges of complex data.
        crange_x = _get_data_range_x(comm_cart, Nxyz_c, (P1, P2))
        crange_y = _get_data_range_y(comm_cart, Nxyz_c, (P1, P2))
        crange_z = _get_data_range_z(comm_cart, Nxyz_c, (P1, P2))

        new{T}(comm_cart, P1, P2, Nxyz, rrange_x, crange_x, crange_y, crange_z)
    end

    PencilPlan(comm::MPI.Comm, args...) = PencilPlan(Float64, comm, args...)
end

function show(io::IO, p::PencilPlan{T}) where T
    print(io, "$(typeof(p)) over $(p.P1) × $(p.P2) MPI processes.")
    print(io, "\n\tReal data dimensions:     ", size_global(p))
    print(io, "\n\tLocal input data range:   ", input_range(p), "\t($T)")
    print(io, "\n\tLocal output data range:  ", output_range(p), "\t($(Complex{T}))")
    nothing
end

eltype(p::PencilPlan{T}) where T = T

"""
    size_global(p::PencilPlan)

Global dimensions of 3D input data in real space.
"""
size_global(p::PencilPlan) = p.size_global

"""
    input_range(p::PencilPlan)

Local range of real input data `(x1:x2, y1:y2, z1:z2)`.
"""
input_range(p::PencilPlan) = p.rrange_x

"""
    output_range(p::PencilPlan)

Local range of complex output data `(x1:x2, y1:y2, z1:z2)`.

**Note:** output data should be accessed in `(z, y, x)` order.
"""
output_range(p::PencilPlan) = p.crange_z

"""
    allocate_input(p::PencilPlan, [extra_dims...])

Allocate input (real) array for the given plan.

Array data is not initialised.

Additional dimensions (for instance representing vector or matrix components)
may be added using the `extra_dims` arguments:

    allocate_input(p, 3)        # 3-component vector field
    allocate_input(p, 3, 4)     # 3x4 tensor field

The extra dimensions are the last (slowest) dimensions of the returned array.

See also: [`allocate_output`](@ref)
"""
function allocate_input(p::PencilPlan{T}, extra_dims::Vararg{Int}) where T
    Nxyz = length.(input_range(p))
    Array{T}(undef, Nxyz..., extra_dims...)
end

"""
    allocate_output(p::PencilPlan, [extra_dims...])

Allocate output (complex) array for the given plan.

See also: [`allocate_input`](@ref)
"""
function allocate_output(p::PencilPlan{T}, extra_dims::Vararg{Int}) where T
    Nx, Ny, Nz = length.(output_range(p))
    Array{Complex{T}}(undef, Nz, Ny, Nx, extra_dims...)
end

"Get Cartesian coordinates of current process in communicator."
function _cart_coords(comm_cart) :: NTuple{3,Int}  # (1, p1, p2)
    maxdims = 3
    coords = MPI.Cart_coords(comm_cart, maxdims) .+ 1  # >= 1
    coords[1], coords[2], coords[3]
end

"Length of first dimension when data is in complex space."
_complex_size_x(Nx) = (Nx >>> 1) + 1  # Nx/2 + 1

function _local_range(p, P, N)
    @assert 1 <= p <= P
    a = (N * (p - 1)) ÷ P + 1
    b = (N * p) ÷ P
    a:b
end

"Get local data range in x-pencil configuration."
function _get_data_range_x(comm_cart, Nxyz, (P1, P2))
    Pxyz = 1, P1, P2
    ijk = _cart_coords(comm_cart)
    @assert all(1 .<= ijk .<= Pxyz)
    _local_range.(ijk, Pxyz, Nxyz)
end

function _get_data_range_y(comm_cart, Nxyz, (P1, P2))
    Pxyz = P1, 1, P2
    j, i, k = _cart_coords(comm_cart)
    ijk = (i, j, k)
    @assert all(1 .<= ijk .<= Pxyz)
    _local_range.(ijk, Pxyz, Nxyz)
end

function _get_data_range_z(comm_cart, Nxyz, (P1, P2))
    Pxyz = P1, P2, 1
    k, i, j = _cart_coords(comm_cart)
    ijk = (i, j, k)
    @assert all(1 .<= ijk .<= Pxyz)
    _local_range.(ijk, Pxyz, Nxyz)
end

end # module
