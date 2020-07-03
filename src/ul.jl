# This file is based on JuliaLang/LinearAlgebra/src/lu.jl, a part of Julia. 
# License is MIT: https://julialang.org/license

####################
# UL Factorization #
####################
"""
    UL <: Factorization

Matrix factorization type of the `UL` factorization of a square matrix `A`. This
is the return type of [`ul`](@ref), the corresponding matrix factorization function.

The individual components of the factorization `F::UL` can be accessed via [`getproperty`](@ref):

| Component | Description                              |
|:----------|:-----------------------------------------|
| `F.U`     | `U` (upper triangular) part of `UL`      |
| `F.L`     | `L` (unit lower triangular) part of `UL` |
| `F.p`     | (right) permutation `Vector`             |
| `F.P`     | (right) permutation `Matrix`             |

Iterating the factorization produces the components `F.U`, `F.L`, and `F.p`.

# Examples
```jldoctest
julia> A = [4 3; 6 3]
2×2 Array{Int64,2}:
 4  3
 6  3

julia> F = ul(A)
UL{Float64,Array{Float64,2}}
L factor:
2×2 Array{Float64,2}:
 1.0       0.0
 0.666667  1.0
U factor:
2×2 Array{Float64,2}:
 6.0  3.0
 0.0  1.0

julia> F.L * F.U == A[F.p, :]
true

julia> l, u, p = ul(A); # destructuring via iteration

julia> l == F.L && u == F.U && p == F.p
true
```
"""
struct UL{T,S<:AbstractMatrix{T},IPIV<:AbstractVector{<:Integer}} <: Factorization{T}
    factors::S
    ipiv::IPIV
    info::BlasInt

    function UL{T,S,IPIV}(factors, ipiv, info) where {T,S<:AbstractMatrix{T},IPIV<:AbstractVector{<:Integer}}
        require_one_based_indexing(factors)
        new{T,S,IPIV}(factors, ipiv, info)
    end
end
function UL(factors::AbstractMatrix{T}, ipiv::AbstractVector{<:Integer}, info::Integer) where {T}
    UL{T,typeof(factors),typeof(ipiv)}(factors, ipiv, BlasInt(info))
end
function UL{T}(factors::AbstractMatrix, ipiv::AbstractVector{<:Integer}, info::Integer) where {T}
    UL(convert(AbstractMatrix{T}, factors),
       ipiv,
       info)
end

function UL{T,S}(factors::AbstractMatrix, ipiv::AbstractVector{<:Integer}, info::Integer) where {T,S<:AbstractMatrix{T}}
    UL(convert(S, factors),
       ipiv,
       info)
end


# iteration for destructuring into components
Base.iterate(S::UL) = (S.U, Val(:L))
Base.iterate(S::UL, ::Val{:L}) = (S.L, Val(:p))
Base.iterate(S::UL, ::Val{:p}) = (S.p, Val(:done))
Base.iterate(S::UL, ::Val{:done}) = nothing

adjoint(F::UL) = Adjoint(F)
transpose(F::UL) = Transpose(F)

# AbstractMatrix
function ul!(A::AbstractMatrix{T}, pivot::Union{Val{false}, Val{true}} = Val(true);
             check::Bool = true) where T<:BlasFloat
    return generic_ulfact!(A, pivot; check = check)
end
function ul!(A::HermOrSym, pivot::Union{Val{false}, Val{true}} = Val(true); check::Bool = true)
    copytri!(A.data, A.uplo, isa(A, Hermitian))
    ul!(A.data, pivot; check = check)
end

"""
    ul!(A, pivot=Val(true); check = true) -> UL

`ul!` is the same as [`ul`](@ref), but saves space by overwriting the
input `A`, instead of creating a copy. An [`InexactError`](@ref)
exception is thrown if the factorization produces a number not representable by the
element type of `A`, e.g. for integer types.

# Examples
```jldoctest
julia> A = [4. 3.; 6. 3.]
2×2 Array{Float64,2}:
 4.0  3.0
 6.0  3.0

julia> F = ul!(A)
UL{Float64,Array{Float64,2},Vector{Int}}
L factor:
2×2 Array{Float64,2}:
 1.0       0.0
 0.666667  1.0
U factor:
2×2 Array{Float64,2}:
 6.0  3.0
 0.0  1.0

julia> iA = [4 3; 6 3]
2×2 Array{Int64,2}:
 4  3
 6  3

julia> ul!(iA)
ERROR: InexactError: Int64(0.6666666666666666)
Stacktrace:
[...]
```
"""
ul!(A::AbstractMatrix, pivot::Union{Val{false}, Val{true}} = Val(true); check::Bool = true) =
    generic_ulfact!(A, pivot; check = check)
function generic_ulfact!(A::AbstractMatrix{T}, ::Val{Pivot} = Val(true);
                         check::Bool = true) where {T,Pivot}
    m, n = size(A)
    minmn = min(m,n)
    info = 0
    ipiv = Vector{BlasInt}(undef, minmn)
    @inbounds begin
        for k = minmn:-1:1
            # find index max
            kp = k
            if Pivot
                amax = abs(zero(T))
                for i = 1:k
                    absi = abs(A[i,k])
                    if absi > amax
                        kp = i
                        amax = absi
                    end
                end
            end
            ipiv[k] = kp
            if !iszero(A[kp,k])
                if k != kp
                    # Interchange
                    for i = 1:n
                        tmp = A[k,i]
                        A[k,i] = A[kp,i]
                        A[kp,i] = tmp
                    end
                end
                # Scale first coulmn
                Akkinv = inv(A[k,k])
                for i = 1:k-1
                    A[i,k] *= Akkinv
                end
            elseif info == 0
                info = k
            end
            # Update the rest
            for j = 1:k-1
                for i = 1:k-1
                    A[i,j] -= A[i,k]*A[k,j]
                end
            end
        end
    end
    check && checknonsingular(info, Val{Pivot}())
    return UL{T}(A, ipiv, convert(BlasInt, info))
end

function ultype(T::Type)
    # In generic_ulfact!, the elements of the lower part of the matrix are
    # obtained using the division of two matrix elements. Hence their type can
    # be different (e.g. the division of two types with the same unit is a type
    # without unit).
    # The elements of the upper part are obtained by U - U * L
    # where U is an upper part element and L is a lower part element.
    # Therefore, the types LT, UT should be invariant under the map:
    # (LT, UT) -> begin
    #     L = oneunit(UT) / oneunit(UT)
    #     U = oneunit(UT) - oneunit(UT) * L
    #     typeof(L), typeof(U)
    # end
    # The following should handle most cases
    UT = typeof(oneunit(T) - oneunit(T) * (oneunit(T) / (oneunit(T) + zero(T))))
    LT = typeof(oneunit(UT) / oneunit(UT))
    S = promote_type(T, LT, UT)
end

# for all other types we must promote to a type which is stable under division
"""
    ul(A, pivot=Val(true); check = true) -> F::UL

Compute the UL factorization of `A`.

When `check = true`, an error is thrown if the decomposition fails.
When `check = false`, responsibility for checking the decomposition's
validity (via [`issuccess`](@ref)) lies with the user.

In most cases, if `A` is a subtype `S` of `AbstractMatrix{T}` with an element
type `T` supporting `+`, `-`, `*` and `/`, the return type is `UL{T,S{T}}`. If
pivoting is chosen (default) the element type should also support [`abs`](@ref) and
[`<`](@ref).

The individual components of the factorization `F` can be accessed via [`getproperty`](@ref):

| Component | Description                         |
|:----------|:------------------------------------|
| `F.U`     | `U` (upper triangular) part of `UL` |
| `F.L`     | `L` (lower triangular) part of `UL` |
| `F.p`     | (right) permutation `Vector`        |
| `F.P`     | (right) permutation `Matrix`        |

Iterating the factorization produces the components `F.L`, `F.U`, and `F.p`.

The relationship between `F` and `A` is

`F.L*F.U == A[F.p, :]`

`F` further supports the following functions:

| Supported function               | `UL` | `UL{T,Tridiagonal{T}}` |
|:---------------------------------|:-----|:-----------------------|
| [`/`](@ref)                      | ✓    |                        |
| [`\\`](@ref)                     | ✓    | ✓                      |
| [`inv`](@ref)                    | ✓    | ✓                      |
| [`det`](@ref)                    | ✓    | ✓                      |
| [`logdet`](@ref)                 | ✓    | ✓                      |
| [`logabsdet`](@ref)              | ✓    | ✓                      |
| [`size`](@ref)                   | ✓    | ✓                      |

# Examples
```jldoctest
julia> A = [4 3; 6 3]
2×2 Array{Int64,2}:
 4  3
 6  3

julia> F = ul(A)
UL{Float64,Array{Float64,2},Vector{Int}}
L factor:
2×2 Array{Float64,2}:
 1.0       0.0
 0.666667  1.0
U factor:
2×2 Array{Float64,2}:
 6.0  3.0
 0.0  1.0

julia> F.L * F.U == A[F.p, :]
true

julia> l, u, p = ul(A); # destructuring via iteration

julia> l == F.L && u == F.U && p == F.p
true
```
"""
function _ul(layout, A::AbstractMatrix{T}, pivot::Union{Val{false}, Val{true}}=Val(true);
            check::Bool = true) where T
    S = ultype(T)
    ul!(copy_oftype(A, S), pivot; check = check)
end

ul(A::AbstractMatrix{T}, pivot::Union{Val{false}, Val{true}}=Val(true); check::Bool = true) where T = 
    _ul(MemoryLayout(A), A, pivot; check=check)

ul(S::UL) = S
function ul(x::Number; check::Bool=true)
    info = x == 0 ? one(BlasInt) : zero(BlasInt)
    check && checknonsingular(info)
    return UL(fill(x, 1, 1), BlasInt[1], info)
end

function UL{T}(F::UL) where T
    M = convert(AbstractMatrix{T}, F.factors)
    UL{T,typeof(M)}(M, F.ipiv, F.info)
end
UL{T,S}(F::UL) where {T,S} = UL{T,S}(convert(S, F.factors), F.ipiv, F.info)
Factorization{T}(F::UL{T}) where {T} = F
Factorization{T}(F::UL) where {T} = UL{T}(F)

copy(A::UL{T,S}) where {T,S} = UL{T,S}(copy(A.factors), copy(A.ipiv), A.info)

size(A::UL)    = size(getfield(A, :factors))
size(A::UL, i) = size(getfield(A, :factors), i)

getU(F::UL) = getU(F, size(F.factors))
function getU(F::UL, _)
    m, n = size(F)
    U = triu!(getfield(F, :factors)[1:m,1:min(m,n)])
    for i = 1:min(m,n); U[i,i] = one(T); end
    return U
end

getL(F::UL) = getL(F, size(F.factors))
function getL(F::UL, _) 
    m, n = size(F)
    tril!(getfield(F, :factors)[1:min(m,n),1:n])
end

function getproperty(F::UL{T,<:AbstractMatrix}, d::Symbol) where T
    m, n = size(F)
    if d === :L
        return getL(F)
    elseif d === :U
        return getU(F)
    elseif d === :p
        return invperm(ipiv2perm(getfield(F, :ipiv), m))
    elseif d === :P
        return Matrix{T}(I, m, m)[:,invperm(F.p)]
    else
        getfield(F, d)
    end
end

Base.propertynames(F::UL, private::Bool=false) =
    (:L, :U, :p, :P, (private ? fieldnames(typeof(F)) : ())...)

issuccess(F::UL) = F.info == 0

function show(io::IO, mime::MIME{Symbol("text/plain")}, F::UL)
    if issuccess(F)
        summary(io, F); println(io)
        println(io, "U factor:")
        show(io, mime, F.U)
        println(io, "\nL factor:")
        show(io, mime, F.L)
    else
        print(io, "Failed factorization of type $(typeof(F))")
    end
end

_apply_inverse_ipiv_rows!(A::UL, B::AbstractVecOrMat) = _ipiv_rows!(A, 1 : length(A.ipiv), B)
_apply_ipiv_rows!(A::UL, B::AbstractVecOrMat) = _ipiv_rows!(A, length(A.ipiv) : -1 : 1, B)

function _ipiv_rows!(A::UL, order::OrdinalRange, B::AbstractVecOrMat)
    for i = order
        if i != A.ipiv[i]
            _swap_rows!(B, i, A.ipiv[i])
        end
    end
    B
end

function _swap_rows!(B::AbstractVector, i::Integer, j::Integer)
    B[i], B[j] = B[j], B[i]
    B
end

function _swap_rows!(B::AbstractMatrix, i::Integer, j::Integer)
    for col = 1 : size(B, 2)
        B[i,col], B[j,col] = B[j,col], B[i,col]
    end
    B
end

_apply_ipiv_cols!(A::UL, B::AbstractVecOrMat) = _ipiv_cols!(A, 1 : length(A.ipiv), B)
_apply_inverse_ipiv_cols!(A::UL, B::AbstractVecOrMat) = _ipiv_cols!(A, length(A.ipiv) : -1 : 1, B)

function _ipiv_cols!(A::UL, order::OrdinalRange, B::AbstractVecOrMat)
    for i = order
        if i != A.ipiv[i]
            _swap_cols!(B, i, A.ipiv[i])
        end
    end
    B
end

function rdiv!(A::AbstractVecOrMat, B::UL{<:Any,<:AbstractMatrix})
    rdiv!(rdiv!(A, LowerTriangular(B.factors)), UnitUpperTriangular(B.factors))
    _apply_inverse_ipiv_cols!(B, A)
end


function ldiv!(A::UL{<:Any,<:AbstractMatrix}, B::AbstractVecOrMat)
    _apply_ipiv_rows!(A, B)
    ldiv!(LowerTriangular(A.factors), ldiv!(UnitUpperTriangular(A.factors), B))
end

function ldiv!(transA::Transpose{<:Any,<:UL{<:Any,<:AbstractMatrix}}, B::AbstractVecOrMat)
    A = transA.parent
    ldiv!(transpose(UnitUpperTriangular(A.factors)), ldiv!(transpose(LowerTriangular(A.factors)), B))
    _apply_inverse_ipiv_rows!(A, B)
end

ldiv!(adjF::Adjoint{T,<:UL{T,<:AbstractMatrix}}, B::AbstractVecOrMat{T}) where {T<:Real} =
    (F = adjF.parent; ldiv!(transpose(F), B))

function ldiv!(adjA::Adjoint{<:Any,<:UL{<:Any,<:AbstractMatrix}}, B::AbstractVecOrMat)
    A = adjA.parent
    ldiv!(adjoint(UnitUpperTriangular(A.factors)), ldiv!(adjoint(LowerTriangular(A.factors)), B))
    _apply_inverse_ipiv_rows!(A, B)
end

(\)(A::Adjoint{<:Any,<:UL}, B::Adjoint{<:Any,<:AbstractVecOrMat}) = A \ copy(B)
(\)(A::Transpose{<:Any,<:UL}, B::Transpose{<:Any,<:AbstractVecOrMat}) = A \ copy(B)

function (/)(A::AbstractMatrix, F::Adjoint{<:Any,<:UL})
    T = promote_type(eltype(A), eltype(F))
    return adjoint(ldiv!(F.parent, copy_oftype(adjoint(A), T)))
end
# To avoid ambiguities with definitions in adjtrans.jl and factorizations.jl
(/)(adjA::Adjoint{<:Any,<:AbstractVector}, F::Adjoint{<:Any,<:UL}) = adjoint(F.parent \ adjA.parent)
(/)(adjA::Adjoint{<:Any,<:AbstractMatrix}, F::Adjoint{<:Any,<:UL}) = adjoint(F.parent \ adjA.parent)
function (/)(trA::Transpose{<:Any,<:AbstractVector}, F::Adjoint{<:Any,<:UL})
    T = promote_type(eltype(trA), eltype(F))
    return adjoint(ldiv!(F.parent, convert(AbstractVector{T}, conj(trA.parent))))
end
function (/)(trA::Transpose{<:Any,<:AbstractMatrix}, F::Adjoint{<:Any,<:UL})
    T = promote_type(eltype(trA), eltype(F))
    return adjoint(ldiv!(F.parent, convert(AbstractMatrix{T}, conj(trA.parent))))
end

function det(F::UL{T}) where T
    n = checksquare(F)
    issuccess(F) || return zero(T)
    P = one(T)
    c = 0
    @inbounds for i = 1:n
        P *= F.factors[i,i]
        if F.ipiv[i] != i
            c += 1
        end
    end
    s = (isodd(c) ? -one(T) : one(T))
    return P * s
end

function logabsdet(F::UL{T}) where T  # return log(abs(det)) and sign(det)
    n = checksquare(F)
    issuccess(F) || return log(zero(real(T))), log(one(T))
    c = 0
    P = one(T)
    abs_det = zero(real(T))
    @inbounds for i = 1:n
        dg_ii = F.factors[i,i]
        P *= sign(dg_ii)
        if F.ipiv[i] != i
            c += 1
        end
        abs_det += log(abs(dg_ii))
    end
    s = ifelse(isodd(c), -one(real(T)), one(real(T))) * P
    abs_det, s
end

inv!(A::UL{T,<:AbstractMatrix}) where {T} =
    ldiv!(A.factors, copy(A), Matrix{T}(I, size(A, 1), size(A, 1)))
inv(A::UL{<:BlasFloat,<:AbstractMatrix}) = inv!(copy(A))

# Tridiagonal

# # See dgttrf.f
# function ul!(A::Tridiagonal{T,V}, pivot::Union{Val{false}, Val{true}} = Val(true);
#              check::Bool = true) where {T,V}
#     n = size(A, 1)
#     info = 0
#     ipiv = Vector{BlasInt}(undef, n)
#     dl = A.dl
#     d = A.d
#     du = A.du
#     if dl === du
#         throw(ArgumentError("off-diagonals of `A` must not alias"))
#     end
#     dl2 = fill!(similar(d, n-2), 0)::V

#     @inbounds begin
#         for i = 1:n
#             ipiv[i] = i
#         end
#         for i = n:-1:3
#             # pivot or not?
#             if pivot === Val(false) || abs(d[i]) >= abs(dl[i])
#                 # No interchange
#                 if d[i] != 0
#                     fact = du[i-1]/d[i]
#                     du[i-1] = fact
#                     d[i-1] -= fact*dl[i-1]
#                     dl2[i] = 0
#                 end
#             else
#                 # Interchange
#                 fact = d[i]/du[i-1]
#                 d[i] = du[i-1]
#                 du[i-1] = fact
#                 tmp = dl[i-1]
#                 dl[i-1] = d[i-1]
#                 d[i-1] = tmp - fact*d[i-1]
#                 dl2[i] = dl[i-1]
#                 dl[i-1] = -fact*dl[i-1]
#                 ipiv[i] = i-1
#             end
#         end
#         if n > 1
#             i = 2
#             if pivot === Val(false) || abs(d[i]) >= abs(dl[i])
#                 if d[i] != 0
#                     fact = du[i-1]/d[i]
#                     du[i-1] = fact
#                     d[i-1] -= fact*dl[i-1]
#                 end
#             else
#                 fact = d[i]/du[i-1]
#                 d[i] = du[i-1]
#                 du[i-1] = fact
#                 tmp = dl[i-1]
#                 dl[i-1] = d[i-1]
#                 d[i-1] = tmp - fact*d[i-1]
#                 ipiv[i] = i-1
#             end
#         end
#         # check for a zero on the diagonal of U
#         for i = 1:n
#             if d[i] == 0
#                 info = i
#                 break
#             end
#         end
#     end
#     B = Tridiagonal{T,V}(dl, d, du, dl2)
#     check && checknonsingular(info, pivot)
#     return UL{T,Tridiagonal{T,V}}(B, ipiv, convert(BlasInt, info))
# end

# function getproperty(F::UL{T,Tridiagonal{T,V}}, d::Symbol) where {T,V}
#     m, n = size(F)
#     if d === :U
#         du = getfield(getfield(F, :factors), :du)
#         U = Array(Bidiagonal(fill!(similar(du, n), one(T)), du, d))
#         for i = 2:n
#             tmp = U[getfield(F, :ipiv)[i], i+1:end]
#             U[getfield(F, :ipiv)[i], i+1:end] = U[i, i+1:end]
#             U[i, i+1:end] = tmp
#         end
#         return U
#     elseif d === :L
#         L = Array(Bidiagonal(getfield(getfield(F, :factors), :d), getfield(getfield(F, :factors), :dl), d))
#         for i = 1:n - 2
#             L[i,i + 2] = getfield(getfield(F, :factors), :du2)[i]
#         end
#         return L
#     elseif d === :p
#         return ipiv2perm(getfield(F, :ipiv), m)
#     elseif d === :P
#         return Matrix{T}(I, m, m)[:,invperm(F.p)]
#     end
#     return getfield(F, d)
# end

# # See dgtts2.f
# function ldiv!(A::UL{T,Tridiagonal{T,V}}, B::AbstractVecOrMat) where {T,V}
#     require_one_based_indexing(B)
#     n = size(A,1)
#     if n != size(B,1)
#         throw(DimensionMismatch("matrix has dimensions ($n,$n) but right hand side has $(size(B,1)) rows"))
#     end
#     nrhs = size(B,2)
#     dl = A.factors.dl
#     d = A.factors.d
#     du = A.factors.du
#     du2 = A.factors.du2
#     ipiv = A.ipiv
#     @inbounds begin
#         for j = 1:nrhs
#             for i = 1:n-1
#                 ip = ipiv[i]
#                 tmp = B[i+1-ip+i,j] - dl[i]*B[ip,j]
#                 B[i,j] = B[ip,j]
#                 B[i+1,j] = tmp
#             end
#             B[n,j] /= d[n]
#             if n > 1
#                 B[n-1,j] = (B[n-1,j] - du[n-1]*B[n,j])/d[n-1]
#             end
#             for i = n-2:-1:1
#                 B[i,j] = (B[i,j] - du[i]*B[i+1,j] - du2[i]*B[i+2,j])/d[i]
#             end
#         end
#     end
#     return B
# end

# function ldiv!(transA::Transpose{<:Any,<:UL{T,Tridiagonal{T,V}}}, B::AbstractVecOrMat) where {T,V}
#     require_one_based_indexing(B)
#     A = transA.parent
#     n = size(A,1)
#     if n != size(B,1)
#         throw(DimensionMismatch("matrix has dimensions ($n,$n) but right hand side has $(size(B,1)) rows"))
#     end
#     nrhs = size(B,2)
#     dl = A.factors.dl
#     d = A.factors.d
#     du = A.factors.du
#     du2 = A.factors.du2
#     ipiv = A.ipiv
#     @inbounds begin
#         for j = 1:nrhs
#             B[1,j] /= d[1]
#             if n > 1
#                 B[2,j] = (B[2,j] - du[1]*B[1,j])/d[2]
#             end
#             for i = 3:n
#                 B[i,j] = (B[i,j] - du[i-1]*B[i-1,j] - du2[i-2]*B[i-2,j])/d[i]
#             end
#             for i = n-1:-1:1
#                 if ipiv[i] == i
#                     B[i,j] = B[i,j] - dl[i]*B[i+1,j]
#                 else
#                     tmp = B[i+1,j]
#                     B[i+1,j] = B[i,j] - dl[i]*tmp
#                     B[i,j] = tmp
#                 end
#             end
#         end
#     end
#     return B
# end

# # Ac_ldiv_B!(A::UL{T,Tridiagonal{T}}, B::AbstractVecOrMat) where {T<:Real} = At_ldiv_B!(A,B)
# function ldiv!(adjA::Adjoint{<:Any,UL{T,Tridiagonal{T,V}}}, B::AbstractVecOrMat) where {T,V}
#     require_one_based_indexing(B)
#     A = adjA.parent
#     n = size(A,1)
#     if n != size(B,1)
#         throw(DimensionMismatch("matrix has dimensions ($n,$n) but right hand side has $(size(B,1)) rows"))
#     end
#     nrhs = size(B,2)
#     dl = A.factors.dl
#     d = A.factors.d
#     du = A.factors.du
#     du2 = A.factors.du2
#     ipiv = A.ipiv
#     @inbounds begin
#         for j = 1:nrhs
#             B[1,j] /= conj(d[1])
#             if n > 1
#                 B[2,j] = (B[2,j] - conj(du[1])*B[1,j])/conj(d[2])
#             end
#             for i = 3:n
#                 B[i,j] = (B[i,j] - conj(du[i-1])*B[i-1,j] - conj(du2[i-2])*B[i-2,j])/conj(d[i])
#             end
#             for i = n-1:-1:1
#                 if ipiv[i] == i
#                     B[i,j] = B[i,j] - conj(dl[i])*B[i+1,j]
#                 else
#                     tmp = B[i+1,j]
#                     B[i+1,j] = B[i,j] - conj(dl[i])*tmp
#                     B[i,j] = tmp
#                 end
#             end
#         end
#     end
#     return B
# end

rdiv!(B::AbstractMatrix, A::UL) = transpose(ldiv!(transpose(A), transpose(B)))
rdiv!(B::AbstractMatrix, A::Transpose{<:Any,<:UL}) = transpose(ldiv!(A.parent, transpose(B)))
rdiv!(B::AbstractMatrix, A::Adjoint{<:Any,<:UL}) = adjoint(ldiv!(A.parent, adjoint(B)))

# Conversions
AbstractMatrix(F::UL) = (F.L * F.U)[invperm(F.p),:]
AbstractArray(F::UL) = AbstractMatrix(F)
Matrix(F::UL) = Array(AbstractArray(F))
Array(F::UL) = Matrix(F)

# function Tridiagonal(F::UL{T,Tridiagonal{T,V}}) where {T,V}
#     n = size(F, 1)

#     dl  = copy(F.factors.dl)
#     d   = copy(F.factors.d)
#     du  = copy(F.factors.du)
#     du2 = copy(F.factors.du2)

#     for i = n - 1:-1:1
#         li         = dl[i]
#         dl[i]      = li*d[i]
#         d[i + 1]  += li*du[i]
#         if i < n - 1
#             du[i + 1] += li*du2[i]
#         end

#         if F.ipiv[i] != i
#             tmp   = dl[i]
#             dl[i] = d[i]
#             d[i]  = tmp

#             tmp      = d[i + 1]
#             d[i + 1] = du[i]
#             du[i]    = tmp

#             if i < n - 1
#                 tmp       = du[i + 1]
#                 du[i + 1] = du2[i]
#                 du2[i]    = tmp
#             end
#         end
#     end
#     return Tridiagonal(dl, d, du)
# end
# AbstractMatrix(F::UL{T,Tridiagonal{T,V}}) where {T,V} = Tridiagonal(F)
# AbstractArray(F::UL{T,Tridiagonal{T,V}}) where {T,V} = AbstractMatrix(F)
# Matrix(F::UL{T,Tridiagonal{T,V}}) where {T,V} = Array(AbstractArray(F))
# Array(F::UL{T,Tridiagonal{T,V}}) where {T,V} = Matrix(F)