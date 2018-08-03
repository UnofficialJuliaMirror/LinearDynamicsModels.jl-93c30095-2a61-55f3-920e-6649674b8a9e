module LinearDynamicsModels

using LinearAlgebra
using StaticArrays
using DifferentialDynamicsModels
using ForwardDiff
using Requires
using MacroTools

import DifferentialDynamicsModels: SteeringBVP
import DifferentialDynamicsModels: state_dim, control_dim, duration, propagate, instantaneous_control
export LinearDynamics, ZeroOrderHoldLinearization, FirstOrderHoldLinearization, linearize
export NIntegratorDynamics, DoubleIntegratorDynamics, TripleIntegratorDynamics

include("utils.jl")

# Continous-Time Linear Time-Invariant Systems
struct LinearDynamics{Dx,Du,TA<:StaticMatrix{Dx,Dx},TB<:StaticMatrix{Dx,Du},Tc<:StaticVector{Dx}} <: DifferentialDynamics
    A::TA
    B::TB
    c::Tc
end

state_dim(::LinearDynamics{Dx,Du}) where {Dx,Du} = Dx
control_dim(::LinearDynamics{Dx,Du}) where {Dx,Du} = Du

(f::LinearDynamics{Dx,Du})(x::StaticVector{Dx}, u::StaticVector{Du}) where {Dx,Du} = f.A*x + f.B*u + f.c
function propagate(f::LinearDynamics{Dx,Du}, x::StaticVector{Dx}, SC::StepControl{Du}) where {Dx,Du}
    y = f.B*SC.u + f.c
    eᴬᵗ, ∫eᴬᵗy = integrate_expAt_B(f.A, y, SC.t)
    eᴬᵗ*x + ∫eᴬᵗy
end
function propagate(f::LinearDynamics{Dx,Du}, x::StaticVector{Dx}, RC::RampControl{Du}) where {Dx,Du}
    y = f.B*RC.uf + f.c
    eᴬᵗ, ∫eᴬᵗy = integrate_expAt_B(f.A, y, RC.t)
    z = f.B*(RC.u0 - RC.uf)
    _, _, ∫eᴬᵗztdt⁻¹ = integrate_expAt_Bt_dtinv(f.A, z, RC.t)
    eᴬᵗ*x + ∫eᴬᵗy + ∫eᴬᵗztdt⁻¹
end

# Discrete-Time Linear Time-Invariant Systems
include("linearization.jl")

# NIntegrators (DoubleIntegrator, TripleIntegrator, etc.)
function NIntegratorDynamics(::Val{N}, ::Val{D}, ::Type{T} = Rational{Int}) where {N,D,T}
    A = diagm(Val(D) => ones(SVector{(N-1)*D,T}))
    B = [zeros(SMatrix{(N-1)*D,D,T}); SMatrix{D,D,T}(I)]
    c = zeros(SVector{N*D,T})
    LinearDynamics(A, B, c)
end
NIntegratorDynamics(N::Int, D::Int, ::Type{T} = Rational{Int}) where {T} = NIntegratorDynamics(Val(N), Val(D), T)
DoubleIntegratorDynamics(D::Int, ::Type{T} = Rational{Int}) where {T} = NIntegratorDynamics(2, D, T)
TripleIntegratorDynamics(D::Int, ::Type{T} = Rational{Int}) where {T} = NIntegratorDynamics(3, D, T)

# TimePlusQuadraticControl BVPs
function SteeringBVP(f::LinearDynamics{Dx,Du}, j::TimePlusQuadraticControl{Du};
                     compile::Union{Val{false},Val{true}}=Val(false)) where {Dx,Du}
    compile === Val(true) ? error("Run `using SymPy` to enable SteeringBVP compilation.") :
                            SteeringBVP(f, j, EmptySteeringConstraints(), EmptySteeringCache())
end

## Ad Hoc Steering
struct LinearQuadraticSteeringControl{Dx,Du,T,
                                      Tx0<:StaticVector{Dx},
                                      Txf<:StaticVector{Dx},
                                      TA<:StaticMatrix{Dx,Dx},
                                      TB<:StaticMatrix{Dx,Du},
                                      Tc<:StaticVector{Dx},
                                      TR<:StaticMatrix{Du,Du},
                                      Tz<:StaticVector{Dx}} <: ControlInterval
    t::T
    x0::Tx0
    xf::Txf
    A::TA
    B::TB
    c::Tc
    R::TR
    z::Tz
end
duration(lqsc::LinearQuadraticSteeringControl) = lqsc.t
propagate(f::LinearDynamics, x::State, lqsc::LinearQuadraticSteeringControl) = (x - lqsc.x0) + lqsc.xf
function propagate(f::LinearDynamics, x::State, lqsc::LinearQuadraticSteeringControl, s::Number)
    x0, A, B, c, R, z = lqsc.x0, lqsc.A, lqsc.B, lqsc.c, lqsc.R, lqsc.z
    eᴬˢ, ∫eᴬˢc = integrate_expAt_B(A, c, s)
    Gs = integrate_expAt_B_expATt(A, B*(R\B'), s)
    (x - x0) + eᴬˢ*x0 + ∫eᴬˢc + Gs*(eᴬˢ'\z)
end
function instantaneous_control(lqsc::LinearQuadraticSteeringControl, s::Number)
    A, B, R, z = lqsc.A, lqsc.B, lqsc.R, lqsc.z
    eᴬˢ = exp(A*s)
    (R\B')*(eᴬˢ'\z)
end

function (bvp::SteeringBVP{D,C,EmptySteeringConstraints,EmptySteeringCache})(x0::StaticVector{Dx},
                                                                             xf::StaticVector{Dx},
                                                                             c_max::T) where {Dx,Du,
                                                                                              T<:Number,
                                                                                              D<:LinearDynamics{Dx,Du},
                                                                                              C<:TimePlusQuadraticControl{Du}}
    f = bvp.dynamics
    j = bvp.cost
    A, B, c, R = f.A, f.B, f.c, j.R
    x0 == xf && return (cost=T(0), controls=LinearQuadraticSteeringControl(T(0), x0, xf, A, B, c, R, zeros(typeof(c))))
    t = optimal_time(bvp, x0, xf, c_max)
    Q = B*(R\B')
    G = integrate_expAt_B_expATt(A, Q, t)
    eᴬᵗ, ∫eᴬᵗc = integrate_expAt_B(A, c, t)
    x̄ = eᴬᵗ*x0 + ∫eᴬᵗc
    z = eᴬᵗ'*(G\(xf - x̄))
    (cost=cost(f, j, x0, xf, t), controls=LinearQuadraticSteeringControl(t, x0, xf, A, B, c, R, z))
end

function cost(f::LinearDynamics{Dx,Du}, j::TimePlusQuadraticControl{Du},
              x0::StaticVector{Dx}, xf::StaticVector{Dx}, t) where {Dx,Du}
    A, B, c, R = f.A, f.B, f.c, j.R
    Q = B*(R\B')
    G = integrate_expAt_B_expATt(A, Q, t)
    eᴬᵗ, ∫eᴬᵗc = integrate_expAt_B(A, c, t)
    x̄ = eᴬᵗ*x0 + ∫eᴬᵗc
    t + (xf - x̄)'*(G\(xf - x̄))
end

function dcost(f::LinearDynamics{Dx,Du}, j::TimePlusQuadraticControl{Du},
               x0::StaticVector{Dx}, xf::StaticVector{Dx}, t) where {Dx,Du}
    A, B, c, R = f.A, f.B, f.c, j.R
    Q = B*(R\B')
    G = integrate_expAt_B_expATt(A, Q, t)
    eᴬᵗ, ∫eᴬᵗc = integrate_expAt_B(A, c, t)
    x̄ = eᴬᵗ*x0 + ∫eᴬᵗc
    z = eᴬᵗ'*(G\(xf - x̄))
    1 - 2*(A*x0 + c)'*z - z'*Q*z
end

function optimal_time(bvp::SteeringBVP{D,C,EmptySteeringConstraints,EmptySteeringCache},
                      x0::StaticVector{Dx},
                      xf::StaticVector{Dx},
                      t_max::T) where {Dx,Du,T<:Number,D<:LinearDynamics{Dx,Du},C<:TimePlusQuadraticControl{Du}}
    t = bisection(t -> dcost(bvp.dynamics, bvp.cost, x0, xf, t), t_max/100, t_max)
    t !== nothing ? t : golden_section(cost, t_max/100, t_max)
end

## Compiled Steering Functions (enabled by `using SymPy`; compiled `SteeringBVP`s return `BVPControl`s)
function __init__()
    @require SymPy="24249f21-da20-56a4-8eb1-6a02cf4ae2e6" include("sympy_bvp_compilation.jl")
end

end # module
