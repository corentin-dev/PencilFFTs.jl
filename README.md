# PencilFFTs.jl

[![docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://jipolanco.github.io/PencilFFTs.jl/stable/)
[![docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://jipolanco.github.io/PencilFFTs.jl/dev/)
[![Build status](https://travis-ci.com/jipolanco/PencilFFTs.jl.svg?branch=master)](https://travis-ci.com/jipolanco/PencilFFTs.jl)

Fast Fourier transforms of MPI-distributed Julia arrays.

This package provides functionality to distribute multidimensional arrays among
MPI processes, and to perform multidimensional FFTs (and related transforms) on
them.

The name of this package originates from the decomposition of 3D domains along
two out of three dimensions, sometimes called *pencil* decomposition.
This is illustrated by the figure below
([source](https://hal.archives-ouvertes.fr/tel-02084215v1)),
where each coloured block is managed by a different MPI process.
Typically, one wants to compute FFTs on a scalar or vector field along the
three spatial dimensions.
In the case of a pencil decomposition, 3D FFTs are performed one dimension at
a time (along the non-decomposed direction, using a serial FFT implementation).
Global data transpositions are then needed to switch from one pencil
configuration to the other and perform FFTs along the other dimensions.

![Pencil decomposition of 3D domains.](docs/src/img/pencils.svg)

See the [package documentation](https://jipolanco.github.io/PencilFFTs.jl/stable/)
for more details.

## Similar projects

- [P3DFFT](https://www.p3dfft.net) implements parallel 3D FFTs using pencil
  decomposition in Fortran and C++.

- [2DECOMP&FFT](http://www.2decomp.org) is another parallel 3D FFT library
  using pencil decomposition written in Fortran.
