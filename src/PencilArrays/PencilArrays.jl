"""
Module for multidimensional data decomposition using MPI.

Handles different decomposition configurations and data transpositions between
them. Also defines relevant data structures for handling distributed data.
"""
module PencilArrays

using MPI
using OffsetArrays
using Reexport
using Requires
using TimerOutputs

import Base: @propagate_inbounds
import LinearAlgebra

export Transpositions

export Pencil, PencilArray, MPITopology
export PencilArrayCollection
export ManyPencilArray
export pencil
export gather
export get_comm, get_decomposition, get_permutation, get_timer
export global_view
export ndims_extra, ndims_space, extra_dims
export range_local, size_local, size_global, to_local

# Describes the portion of an array held by a given MPI process.
const ArrayRegion{N} = NTuple{N,UnitRange{Int}} where N

# Modules
include("MPITopologies.jl")
using .MPITopologies
import .MPITopologies: get_comm

# Type definitions
include("pencil.jl")       # Pencil
include("arrays.jl")       # PencilArray
include("multiarrays.jl")  # ManyPencilArray
include("global_view.jl")  # GlobalPencilArray
include("cartesian_indices.jl")  # PermutedLinearIndices, PermutedCartesianIndices

include("data_ranges.jl")
include("permutations.jl")

include("Transpositions.jl")  # Transpositions module

function __init__()
    @require HDF5="f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f" @eval include("hdf5.jl")
end

end
