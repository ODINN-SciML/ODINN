# Helper functions for the staggered grid
"""
    avg(A)

4-point average of a matrix
"""
@views avg(A) = 0.25 .* ( A[1:end-1,1:end-1] .+ A[2:end,1:end-1] .+ A[1:end-1,2:end] .+ A[2:end,2:end] )


"""
    avg_x(A)

2-point average of a matrix's X axis
"""
@views avg_x(A) = 0.5 .* ( A[1:end-1,:] .+ A[2:end,:] )

"""
    avg_y(A)

2-point average of a matrix's Y axis
"""
@views avg_y(A) = 0.5 .* ( A[:,1:end-1] .+ A[:,2:end] )

"""
    diff_x(A)

2-point differential of a matrix's X axis
"""
@views diff_x(A) = (A[begin + 1:end, :] .- A[1:end - 1, :])

"""
    diff_y(A)

2-point differential of a matrix's Y axis
"""
@views diff_y(A) = (A[:, begin + 1:end] .- A[:, 1:end - 1])

"""
    inn(A)

Access the inner part of the matrix (-2,-2)
"""
@views inn(A) = A[2:end-1,2:end-1]

"""
    inn1(A)

Access the inner part of the matrix (-1,-1)
"""
@views inn1(A) = A[1:end-1,1:end-1]

"""
fillNaN!(x, fill)

Convert empty matrix grid cells into fill value
"""
function fillNaN!(A, fill=zero(eltype(A)))
    for i in eachindex(A)
        @inbounds A[i] = ifelse(isnan(A[i]), fill, A[i])
    end
end

function fillNaN(A, fill=zero(eltype(A)))
    return @. ifelse(isnan(A), fill, A)
end

function fillZeros!(A, fill=NaN)
    for i in eachindex(A)
        @inbounds A[i] = ifelse(iszero(A[i]), fill, A[i])
    end
end

function fillZeros(A, fill=NaN)
    return @. ifelse(iszero(A), fill, A)
end

"""
    smooth!(A)

Smooth data contained in a matrix with one time step (CFL) of diffusion.
"""
@views function smooth!(A)
    A[2:end-1,2:end-1] .= A[2:end-1,2:end-1] .+ 1.0./4.1.*(diff(diff(A[:,2:end-1], dims=1), dims=1) .+ diff(diff(A[2:end-1,:], dims=2), dims=2))
    A[1,:]=A[2,:]; A[end,:]=A[end-1,:]; A[:,1]=A[:,2]; A[:,end]=A[:,end-1]
end

function smooth(A)
    A_smooth = A[2:end-1,2:end-1] .+ 1.0./4.1.*(diff(diff(A[:,2:end-1], dims=1), dims=1) .+ diff(diff(A[2:end-1,:], dims=2), dims=2))
    @tullio A_smooth_pad[i,j] := A_smooth[pad(i-1,1,1),pad(j-1,1,1)] # Fill borders 
    return A_smooth_pad
end

function reset_epochs()
    @everywhere @eval ODINN global current_epoch = 1
    @everywhere @eval ODINN global loss_history = []
end

function set_current_epoch(epoch)
    @everywhere @eval ODINN global current_epoch = $epoch
end

function make_plots(plots_i)
    @everywhere @eval ODINN global plots = $plots_i
end

function set_use_MB(use_MB_i)
    @everywhere @eval ODINN global use_MB = $use_MB_i
end

function set_run_spinup(run_spinup_i)
    @everywhere @eval ODINN global run_spinup = $run_spinup_i
end

function set_use_spinup(use_spinup_i)
    @everywhere @eval ODINN global use_spinup = $use_spinup_i
end

function set_create_ref_dataset(create_ref_dataset_i)
    @everywhere @eval ODINN global create_ref_dataset = $create_ref_dataset_i
end

function set_train(train_i)
    @everywhere @eval ODINN global train = $train_i
end

function set_retrain(retrain_i)
    @everywhere @eval ODINN global retrain = $retrain_i
end

function set_ice_thickness_source(it_source_i)
    @everywhere @eval ODINN global ice_thickness_source = $it_source_i
end

function get_gdir_refs(refs, gdirs)
    gdir_refs = []
    for (ref, gdir) in zip(refs, gdirs)
        push!(gdir_refs, Dict("RGI_ID"=>gdir.rgi_id,
                                "H"=>ref["H"],
                                "Vx"=>ref["Vx"],
                                "Vy"=>ref["Vy"],
                                "S"=>ref["S"],
                                "B"=>ref["B"]))
    end
    return gdir_refs
end

"""
    generate_batches(batch_size, UD, target, gdirs_climate_batches, gdir_refs, context_batches; gtd_grids=nothing, shuffle=true)

Generates batches for the UE inversion problem based on input data and feed them to the loss function.
"""
function generate_batches(batch_size, UD, target::String, gdirs_climate_batches, gdir_refs, context_batches; gtd_grids=nothing, shuffle=true)
    targets = repeat([target], length(gdirs_climate_batches))
    UDs = repeat([UD], length(gdirs_climate_batches))
    if isnothing(gtd_grids) 
        gtd_grids = repeat([nothing], length(gdirs_climate_batches))
        batches = (UDs, gdirs_climate_batches, gdir_refs, context_batches, gtd_grids, targets)
    else
        batches = (UDs, gdirs_climate_batches, gdir_refs, context_batches, gtd_grids, targets)
    end
    train_loader = Flux.Data.DataLoader(batches, batchsize=batch_size)

    return train_loader
end

"""
    generate_batches(batch_size, UA, gdirs_climate_batches, context_batches, gdir_refs, UDE_settings; shuffle=true))

Generates batches for the UDE problem based on input data and feed them to the loss function.
"""
function generate_batches(batch_size, UA, gdirs_climate_batches, context_batches, gdir_refs, UDE_settings; shuffle=true)
    UAs = repeat([UA], length(gdirs_climate_batches))
    UDE_settings_batches = repeat([UDE_settings], length(gdirs_climate_batches))
    batches = (UAs, gdirs_climate_batches, context_batches, gdir_refs, UDE_settings_batches)
    train_loader = Flux.Data.DataLoader(batches, batchsize=batch_size, shuffle=shuffle)

    return train_loader
end


"""
    get_NN()

Generates a neural network.
"""
function get_NN(θ_trained)
    UA = Chain(
        Dense(1,3, x->softplus.(x)),
        Dense(3,10, x->softplus.(x)),
        Dense(10,3, x->softplus.(x)),
        Dense(3,1, sigmoid_A)
    )
    # See if parameters need to be retrained or not
    θ, UA_f = Flux.destructure(UA)
    if !isempty(θ_trained)
        θ = θ_trained
    end
    return UA_f, θ
end

function get_NN_inversion(θ_trained, target)
    if target == "D"
        U, θ = get_NN_inversion_D(θ_trained)
    elseif target == "A"
        U, θ = get_NN_inversion_A(θ_trained)
    end
    return U, θ
end

function get_NN_inversion_A(θ_trained)
    UA = Chain(
        Dense(1,3, x->softplus.(x)),
        Dense(3,10, x->softplus.(x)),
        Dense(10,3, x->softplus.(x)),
        Dense(3,1, softplus)
    )
    # See if parameters need to be retrained or not
    θ, UA_f = Flux.destructure(UA)
    if !isempty(θ_trained)
        θ = θ_trained
    end
    return UA_f, θ
end

function get_NN_inversion_D(θ_trained)
    UD = Chain(
        Dense(3,20, x->softplus.(x)),
        Dense(20,15, x->softplus.(x)),
        Dense(15,10, x->softplus.(x)),
        Dense(10,5, x->softplus.(x)),
        Dense(5,1, softplus) # force diffusivity to be positive
    )
    # See if parameters need to be retrained or not
    θ, UD_f = Flux.destructure(UD)
    if !isempty(θ_trained)
        θ = θ_trained
    end
    return UD_f, θ
end

"""
    predict_A̅(UA_f, θ, temp)

Predicts the value of A with a neural network based on the long-term air temperature.
"""
function predict_A̅(UA_f, θ, temp)
    UA = UA_f(θ)
    return UA(temp) #.* 1e-17
end

function sigmoid_A(x) 
    minA_out = 8.0f-3 # /!\     # these depend on predict_A̅, so careful when changing them!
    maxA_out = 8.0f0
    return minA_out + (maxA_out - minA_out) / ( 1.0f0 + exp(-x) )
end

function sigmoid_A_inv(x) 
    minA_out = 8.0e-4 # /!\     # these depend on predict_A̅, so careful when changing them!
    maxA_out = 8.0e2
    return minA_out + (maxA_out - minA_out) / ( 1.0 + exp(-x) )
end

# Convert Pythonian date to Julian date
function jldate(pydate)
    return Date(pydate.dt.year.data[1], pydate.dt.month.data[1], pydate.dt.day.data[1])
end

function save_plot(plot, path, filename)
    Plots.savefig(plot,joinpath(path,"png","$filename-$(current_epoch[]).png"))
    Plots.savefig(plot,joinpath(path,"pdf","epoch$(current_epoch[]).pdf"))
end

function generate_plot_folders(path)
    if !isdir(joinpath(path,"png")) || !isdir(joinpath(path,"pdf"))
        mkpath(joinpath(path,"png"))
        mkpath(joinpath(path,"pdf"))
    end
end

"""
    config_training_state(θ_trained)

Configure training state with current epoch and its loss history. 
"""
function config_training_state(θ_trained)
    if length(θ_trained) == 0
        reset_epochs()
    else
        # Remove loss history from unfinished trainings
        deleteat!(loss_history, current_epoch:length(loss_history))
    end
end

# Polynomial fit for Cuffey and Paterson data 
A_f = fit(A_values[1,:], A_values[2,:]) # degree = length(xs) - 1

"""
    A_fake(temp, noise=false)

Fake law establishing a theoretical relationship between ice viscosity (A) and long-term air temperature.
"""
function A_fake(temp, A_noise=nothing, noise=false)
    # A = @. minA + (maxA - minA) * ((temp-minT)/(maxT-minT) )^2
    A = A_f.(temp) # polynomial fit
    if noise[]
        A = abs.(A .+ A_noise)
    end
    return A
end

function build_D_features(H::Matrix, temp, ∇S)
    ∇S_flat = ∇S[inn1(H) .!= 0.0] # flatten
    H_flat = H[H .!= 0.0] # flatten
    T_flat = repeat(temp,length(H_flat))
    X = Flux.normalise(hcat(H_flat,T_flat,∇S_flat))' # build feature matrix
    return X
end

function build_D_features(H::Float64, temp::Float64, ∇S::Float64)
    X = Flux.normalise(hcat([H],[temp],[∇S]))' # build feature matrix
    return X
end

function predict_diffusivity(UD_f, θ, X)
    UD = UD_f(θ)
    return UD(X)[1,:]
end


