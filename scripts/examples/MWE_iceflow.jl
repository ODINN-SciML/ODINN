using Statistics
using LinearAlgebra
using Random 
using OrdinaryDiffEq
using DiffEqFlux
using Flux
using Tullio
using RecursiveArrayTools
using ComponentArrays
using Infiltrator
using Plots

const t₁ = 5                 # number of simulation years 
const ρ = 900f0                     # Ice density [kg / m^3]
const g = 9.81f0                    # Gravitational acceleration [m / s^2]
const n = 3f0                       # Glen's flow law exponent
const maxA = 8f-16
const minA = 3f-17
const maxT = 1f0
const minT = -25f0
A = 1.3f-24 #2e-16  1 / Pa^3 s
A *= Float32(60 * 60 * 24 * 365.25) # [1 / Pa^3 yr]
C = 0
α = 0

@views avg(A) = 0.25 .* ( A[1:end-1,1:end-1] .+ A[2:end,1:end-1] .+ A[1:end-1,2:end] .+ A[2:end,2:end] )
@views avg_x(A) = 0.5 .* ( A[1:end-1,:] .+ A[2:end,:] )
@views avg_y(A) = 0.5 .* ( A[:,1:end-1] .+ A[:,2:end] )
@views diff_x(A) = (A[begin + 1:end, :] .- A[1:end - 1, :])
@views diff_y(A) = (A[:, begin + 1:end] .- A[:, 1:end - 1])
@views inn(A) = A[2:end-1,2:end-1]

function ref_glacier(temps, H₀)
      
    H = deepcopy(H₀)
    
    # Initialize all matrices for the solver
    S, dSdx, dSdy = zeros(Float32,nx,ny),zeros(Float32,nx-1,ny),zeros(Float32,nx,ny-1)
    dSdx_edges, dSdy_edges, ∇S = zeros(Float32,nx-1,ny-2),zeros(Float32,nx-2,ny-1),zeros(Float32,nx-1,ny-1)
    D, dH, Fx, Fy = zeros(Float32,nx-1,ny-1),zeros(Float32,nx-2,ny-2),zeros(Float32,nx-1,ny-2),zeros(Float32,nx-2,ny-1)
    V, Vx, Vy = zeros(Float32,nx-1,ny-1),zeros(Float32,nx-1,ny-1),zeros(Float32,nx-1,ny-1)
    
    # Gather simulation parameters
    current_year = Int(0)
    context = ArrayPartition([A], B, S, dSdx, dSdy, D, temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, [current_year])

    # Perform reference simulation with forward model 
    println("Running forward PDE ice flow model...\n")
    iceflow_prob = ODEProblem(iceflow!,H,(0.0,t₁),context)
    iceflow_sol = solve(iceflow_prob, BS3(), reltol=1e-6, progress=true, saveat=1.0, progress_steps = 1)

    return Float32.(iceflow_sol[end])
end

function iceflow!(dH, H, context,t)
    # Unpack parameters
    #A, B, S, dSdx, dSdy, D, temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year 
    current_year = Ref(context.x[18])
    A = Ref(context.x[1])
    
    # Get current year for MB and ELA
    year = floor(Int, t) + 1
    if year != current_year[] && year <= t₁
        temp = Ref{Float32}(context.x[7][year])
        A[] .= A_fake(temp[])
        current_year[] .= year
    end

    # Compute the Shallow Ice Approximation in a staggered grid
    SIA!(dH, H, context)
end      


function train_iceflow_UDE(H₀, UA, H_ref, temps)
    
    # Gather simulation parameters
    H = deepcopy(H₀)
    
    # Gather simulation parameters
    current_year = 0
    θ = initial_params(UA)
    context = ComponentArray(B=B, C=C, α=α, temps=temps,current_year=current_year, H=H, H_ref=H_ref, θ=θ)
    loss(context) = loss_iceflow(context, UA) # closure

    println("Training iceflow UDE...")
    iceflow_trained = DiffEqFlux.sciml_train(loss, context, RMSProp(0.01), maxiters = 10)

    return iceflow_trained
end

function loss_iceflow(context, UA)

    H_in = deepcopy(context.H)

    # Zygote.ignore() do

    #     predicted_A = predict_A̅(UA, θ, [mean(context.temps[7])]')[1]
    #     fake_A = A_fake(mean(context.temps)) 
    #     A_error = predicted_A - fake_A
    #     println("BEFORE")
    #     println("Predicted A: ", predicted_A)
    #     println("Fake A: ", fake_A)
    #     println("A error: ", A_error)
    # end
    
    H_pred = predict_iceflow(context, UA)

    l_H = sqrt(Flux.Losses.mse(H_pred[H_pred .!= 0.0], context.H_ref[H_pred.!= 0.0]; agg=sum))
    println("Loss = ", l_H)
    #println("θ: ", θ)

    Zygote.ignore() do

        predicted_A = predict_A̅(UA, context.θ, [mean(context.temps)]')[1]
        fake_A = A_fake(mean(context.temps)) 
        A_error = predicted_A - fake_A
        println("AFTER")
        println("Predicted A: ", predicted_A)
        println("Fake A: ", fake_A)
        println("A error: ", A_error)

        display(heatmap(H_pred .- context.H_ref, title="H_pred - H_ref"))

    end


    return l_H
end

function predict_iceflow(context, UA)
    
    tspan = (0.0,t₁)
    H = context.H
    iceflow_UDE!(dH, H, θ, t) = iceflow_NN!(dH, H, θ, t, context, UA) # closure
    iceflow_prob = ODEProblem(iceflow_UDE!,H,tspan)
    # H_pred = solve(iceflow_prob, VCABM(), u0=H, p=context.θ, reltol=1e-6, 
    #                sensealg = BacksolveAdjoint(autojacvec=ZygoteVJP(),checkpointing=true), 
    #                progress=true, progress_steps = 1)
    H_pred = solve(iceflow_prob, BS3(), u0=H, p=context.θ, reltol=1e-6, 
                   sensealg = InterpolatingAdjoint(autojacvec=ZygoteVJP()), save_everystep=false, 
                   progress=true, progress_steps = 1)

    return H_pred[end]
end

function iceflow_NN!(dH, H, θ, t, context, UA)
    
    year = floor(Int, t) + 1
    if year <= t₁
        temp = context.temps[year]
    else
        temp = context.temps[year-1]
    end
    YA = predict_A̅(UA, θ, [temp]) # FastChain prediction requires explicit parameters

    # Compute the Shallow Ice Approximation in a staggered grid
    dH .= SIA!(dH, H, YA, context)

    # println("$t - A: ", YA)
    # println("dH: ", maximum(dH))
    # println("Hmax: ", maximum(H))

end  

"""
    SIA(H, p)

Compute a step of the Shallow Ice Approximation PDE in a forward model
"""

function SIA!(dH, H, context)
    
    # Retrieve parameters
    #A, B, S, dSdx, dSdy, D, norm_temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year, H_ref, H, UA, θ
    A = context.x[1]
    B = context.x[2]
    S = context.x[3]
    dSdx = context.x[4]
    dSdy = context.x[5]
    D = context.x[6]
    dSdx_edges = context.x[8]
    dSdy_edges = context.x[9]
    ∇S = context.x[10]
    Fx = context.x[11]
    Fy = context.x[12]
    
    # Update glacier surface altimetry
    S .= B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx .= diff_x(S) / Δx
    dSdy .= diff_y(S) / Δy
    ∇S .= (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n - 1)/2) 

    Γ = 2 * A * (ρ * g)^n / (n+2) # 1 / m^3 s 
    D .= Γ .* avg(H).^(n + 2) .* ∇S

    # Compute flux components
    dSdx_edges .= diff(S[:,2:end - 1], dims=1) / Δx
    dSdy_edges .= diff(S[2:end - 1,:], dims=2) / Δy
    Fx .= .-avg_y(D) .* dSdx_edges
    Fy .= .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    inn(dH) .= .-(diff(Fx, dims=1) / Δx .+ diff(Fy, dims=2) / Δy) # MB to be added here 
    
end

# Function without mutation for Zygote, with context as a ComponentArray
function SIA!(dH, H, A, context::ComponentArray)
    
    # Retrieve parameters
    B = context.B

    # Update glacier surface altimetry
    S = B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx = diff_x(S) / Δx
    dSdy = diff_y(S) / Δy
    ∇S = (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n - 1)/2) 

    Γ = 2 * A * (ρ * g)^n / (n+2) # 1 / m^3 s 
    D = Γ .* avg(H).^(n + 2) .* ∇S

    # Compute flux components
    dSdx_edges = diff(S[:,2:end - 1], dims=1) / Δx
    dSdy_edges = diff(S[2:end - 1,:], dims=2) / Δy
    Fx = .-avg_y(D) .* dSdx_edges
    Fy = .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    @tullio dH[i,j] := -(diff(Fx, dims=1)[pad(i-1,1,1),pad(j-1,1,1)] / Δx + diff(Fy, dims=2)[pad(i-1,1,1),pad(j-1,1,1)] / Δy) # MB to be added here 

    return dH
end


function A_fake(temp)
    return @. minA + (maxA - minA) * ((temp-minT)/(maxT-minT) )^2
end

predict_A̅(UA, θ, temp) = UA(temp, θ)[1] .* 1e-16


#### Generate reference dataset ####
nx = ny = 100
const B = zeros(Float32, (nx, ny))
const σ = 1000
H₀ = Matrix{Float32}([ 250 * exp( - ( (i - nx/2)^2 + (j - ny/2)^2 ) / σ ) for i in 1:nx, j in 1:ny ])    
Δx = Δy = 50 #m   

const temps =  Vector{Float32}([0.0, -0.5, -0.2, -0.1, -0.3, -0.1, -0.2, -0.3, -0.4, -0.1])
H_ref = ref_glacier(temps, H₀)

# Train UDE
minA_out = 0.3
maxA_out = 8
sigmoid_A(x) = minA_out + (maxA_out - minA_out) / ( 1 + exp(-x) )
UA = FastChain(
        FastDense(1,3, x->tanh.(x)),
        FastDense(3,10, x->tanh.(x)),
        FastDense(10,3, x->tanh.(x)),
        FastDense(3,1, sigmoid_A)
    )

iceflow_trained = train_iceflow_UDE(H₀, UA, H_ref, temps)
