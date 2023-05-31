import Pkg
Pkg.activate(dirname(Base.current_project()))

using Revise
using ODINN
using Test
using JLD2
using Plots
using Infiltrator

ODINN.enable_multiprocessing(1) # Force one single worker

include("PDE_UDE_solve.jl")

# Activate to avoid GKS backend Plot issues in the JupyterHub
ENV["GKSwstype"]="nul"

atol = 0.01
@testset "PDE and UDE SIA solvers without MB" pde_solve_test(atol; MB=false)

atol = 2.0
@testset "PDE and UDE SIA solvers with MB" pde_solve_test(atol; MB=true)

# @testset "SIA UDE training" begin include("UDE_train.jl") end

