
export generate_ref_dataset, train_iceflow_UDE, spinup
export predict_A̅, A_fake

function spinup(gdirs_climate, tspan; solver = RDPK3Sp35(), random_MB=nothing)
    println("Spin up simulation for $(Int(tspan[2]) - Int(tspan[1])) years...\n")
    # Run batches in parallel
    climate_years_list = gdirs_climate[1]
    gdirs = gdirs_climate[2]
    longterm_temps = gdirs_climate[3]
    A_noises = randn(rng_seed(), length(gdirs)) .* noise_A_magnitude
    if isnothing(random_MB)
        refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver;run_spinup=true), gdirs, longterm_temps, climate_years_list, A_noises)
    else
        refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise, MB) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver; run_spinup=true,random_MB=MB), gdirs, longterm_temps, climate_years_list, A_noises, random_MB)
    end

    # Gather information per gdir
    gdir_refs = get_gdir_refs(refs, gdirs)

    spinup_path = joinpath(ODINN.root_dir, "data/spinup")
    if !isdir(spinup_path)
        mkdir(spinup_path)
    end
    jldsave(joinpath(ODINN.root_dir, "data/spinup/gdir_refs.jld2"); gdir_refs)

    GC.gc() # run garbage collector to avoid memory overflow
end

"""
    generate_ref_dataset(temp_series, H₀)

Generate reference dataset based on the iceflow PDE
"""
function generate_ref_dataset(gdirs_climate, tspan; solver = Ralston(), random_MB=nothing)
  
    # Perform reference simulation with forward model 
    println("Running forward PDE ice flow model...\n")
    # Run batches in parallel
    gdirs = gdirs_climate[2]
    longterm_temps = gdirs_climate[3]
    climate_years_list = gdirs_climate[1]
    A_noises = randn(rng_seed(), length(gdirs)) .* noise_A_magnitude
    if isnothing(random_MB)
        # refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver;run_spinup=false), gdirs, longterm_temps, climate_years_list, A_noises)
        refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver;run_spinup=false), gdirs, longterm_temps, climate_years_list, A_noises)
    else
        # refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise, MB) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver; run_spinup=false,random_MB=MB), gdirs, longterm_temps, climate_years_list, A_noises, random_MB)
        refs = @showprogress pmap((gdir, longterm_temp, climate_years, A_noise, MB) -> batch_iceflow_PDE(gdir, longterm_temp, climate_years, A_noise, tspan, solver; run_spinup=false,random_MB=MB), gdirs, longterm_temps, climate_years_list, A_noises, random_MB)
    end

    # Gather information per gdir
    gdir_refs = get_gdir_refs(refs, gdirs)

    GC.gc() # run garbage collector to avoid memory overflow

    return gdir_refs
end

"""
    batch_iceflow_PDE(climate, gdir, context) 

Solve the Shallow Ice Approximation iceflow PDE for a given temperature series batch
"""
function batch_iceflow_PDE(gdir, longterm_temp, years, A_noise, tspan, solver; run_spinup=false, random_MB=nothing) 
    println("Processing glacier: ", gdir.rgi_id)

    context, H = build_PDE_context(gdir, longterm_temp, years, A_noise, tspan; run_spinup=run_spinup, random_MB=random_MB)

    # Callback  
    if use_MB[] && !isnothing(random_MB)
        # Define stop times every one month
        tmin_int = Int(tspan[1])
        tmax_int = Int(tspan[2])+1
        tstops = range(tmin_int+1.0f0/12.0f0, tmax_int, step=1/12.0f0) |> collect
        tstops = filter(x->( (Int(tspan[1])<x) & (x<=Int(tspan[2])) ), tstops)
        B = context.x[2]
        H_y = context.x[21]

        function stop_condition(u,t,integrator) 
            t in tstops
        end
        function action!(integrator)
            # println("Time in cb: ", integrator.t[end])
            year = floor(Int, integrator.t[end]) 
            compute_MB_matrix!(context, B, H_y, year) 
            MB = context.x[25]
            # since this represents the anual mass balance, we need to distribute in 12 months
            integrator.u .+= MB / 12.0f0
        end
        cb_MB = DiscreteCallback(stop_condition, action!)
    else
        tstops = []
        cb_MB = DiscreteCallback((u,t,integrator)->false, nothing)
    end

    refs = simulate_iceflow_PDE(H, context, solver, tstops, cb_MB)

    return refs
end

"""
    simulate_iceflow_PDE(H, context, solver) 

Make forward simulation of the SIA PDE.
"""
function simulate_iceflow_PDE(H, context, solver, tstops, cb_MB)
    tspan = context.x[22]

    iceflow_prob = ODEProblem{true,SciMLBase.FullSpecialize}(iceflow!, H, tspan, tstops=tstops, context)
    iceflow_sol = solve(iceflow_prob, 
                        solver, 
                        callback=cb_MB, 
                        tstops=tstops, 
                        reltol=1e-6, 
                        save_everystep=false, 
                        progress=true, 
                        progress_steps=10)
    @show iceflow_sol.destats
    # Compute average ice surface velocities for the simulated period
    H_ref = iceflow_sol.u[end]
    H_ref[H_ref.<0.0] .= H_ref[H_ref.<0.0] .* 0.0 # remove remaining negative values
    temps = context.x[7]
    B = context.x[2]
    V̄x_ref, V̄y_ref = avg_surface_V(context, H_ref, mean(temps), "PDE") # Average velocity with average temperature
    S = B .+ H_ref # Surface topography
    refs = Dict("Vx"=>V̄x_ref, "Vy"=>V̄y_ref, "H"=>H_ref, "S"=>S, "B"=>B)
    return refs
end

"""
     train_iceflow_UDE(gdirs_climate, tspan, train_settings, gdir_refs, θ_trained=[], UDE_settings=nothing, loss_history=[])

Train the Shallow Ice Approximation iceflow UDE. UDE_settings is optional, and requires a Dict specifiying the `reltol`, 
`sensealg` and `solver` for the UDE.  
"""
function train_iceflow_UDE(gdirs_climate, gdirs_climate_batches, tspan, train_settings, gdir_refs, 
                           θ_trained=[], UDE_settings=nothing, loss_history=[]; random_MB=nothing)
    # Setup default parameters
    if length(θ_trained) == 0
        reset_epochs()
        global loss_history = []
    end
    # Fill default UDE_settings if not available 
    if isnothing(UDE_settings)
        if use_MB[]
            UDE_settings = Dict("reltol"=>10f-6, 
                                "solver"=>RDPK3Sp35(), 
                                "sensealg"=>InterpolatingAdjoint(autojacvec=ReverseDiffVJP())) # Currently just ReverseDiffVJP supports callbacks.
        else
            UDE_settings = Dict("reltol"=>10e-6,
                                "solver"=>RDPK3Sp35(),
                                "sensealg"=>InterpolatingAdjoint(autojacvec=ZygoteVJP())) 

        end
    end

    if isnothing(random_MB)
        ODINN.set_use_MB(false) 
    end

    optimizer = train_settings[1]
    epochs = train_settings[2]
    batch_size = train_settings[3]
    n_gdirs = length(gdirs_climate[2])
    UA_f, θ = get_NN(θ_trained)
    gdirs = gdirs_climate[2]
    climate_years_list = gdirs_climate[1]
    # Build context for all the batches before training
    println("Building context...")
    context_batches = map((gdir, climate_years) -> build_UDE_context(gdir, climate_years, tspan; run_spinup=false, random_MB=random_MB), gdirs, climate_years_list)

    println("Training iceflow UDE...")
    temps = gdirs_climate[3]
    A_noise = randn(rng_seed(), length(gdirs)).* noise_A_magnitude
    training_path = joinpath(root_plots,"training")
    cb_plots(θ, l, UA_f) = callback_plots_A(θ, l, UA_f, temps, A_noise, training_path, batch_size, n_gdirs)
    # Create batches for inversion training 
    train_loader = generate_batches(batch_size, UA_f, gdirs_climate_batches, context_batches, gdir_refs, UDE_settings)
    # Setup optimization of the problem
    if optimization_method == "AD+AD"
        println("Optimization based on pure AD.")
        optf = OptimizationFunction((θ, _, UA_batch, gdirs_climate_batch, context_batch, gdir_refs_batch, UDE_settings_batch)->loss_iceflow(θ, UA_batch, gdirs_climate_batch, context_batch, gdir_refs_batch, UDE_settings_batch), Optimization.AutoZygote())
        optprob = OptimizationProblem(optf, θ)
        iceflow_trained = solve(optprob, 
                                optimizer, ncycle(train_loader, epochs), allow_f_increases=true,
                                callback=cb_plots, progress=true)
    elseif optimization_method == "AD+Diff"
        println("Optimization based on AD for NN and finite differences for ODE solver.")
        η = 0.01
        p = [temps]
        function loc_loss(θ, p)
            loss_iceflow(θ, UA_f, gdirs_climate, context_batches, gdir_refs, UDE_settings)[1] 
        end
        function customized_grad!(g::Vector, θ, p)
            # compute output of NN using temps 
            temp = mean(p[1][1])  # Is this the best way of getting the temperature? 
            ∇θ_A = gradient(θ -> UA_f(θ)([temp])[1], θ)[1]
            loss₀ = loc_loss(θ, p)
            θ₁ = Array{Float32}(θ .+ η .* ∇θ_A)
            loss₁ = loc_loss(θ₁, p)
            scalar_factor = (loss₁ - loss₀) ./ (η * norm(∇θ_A)^2)
            g .= scalar_factor .* ∇θ_A
        end   
        optf = OptimizationFunction((θ,_)->loss(θ), 
                                    grad=customized_grad!)
        optprob = OptimizationProblem(optf, θ, p)
        # cb_plots(θ, l) = callback_plots(θ, l, UA_f, temps, A_noise)
        iceflow_trained = solve(optprob, optimizer, callback=cb_plots, maxiters=epochs)
    end

    return iceflow_trained, UA_f, loss_history
end



callback_plots_A = function (θ, l, UA_f, temps, A_noise, training_path) # callback function to observe training
    println("Epoch #$(current_epoch) - Loss $(loss_type[]): ", l)

    if current_minibatches == 0.0
        avg_temps = [mean(temps[i]) for i in 1:length(temps)]
        p = sortperm(avg_temps)
        avg_temps = avg_temps[p]
        @ignore @infiltrate
        pred_A = predict_A̅(UA_f[1], θ, collect(-23.0:1.0:0.0)')
        pred_A = [pred_A...] # flatten
        true_A = A_fake(avg_temps, A_noise[p], noise)
        true_A_noiseless = A_fake(collect(-23.0:1.0:0.0))

        yticks = collect(0.0:2e-17:8e-17)

        Plots.plot(-23:1:0, true_A_noiseless, label="True noiseless A",c=:lightsteelblue2)
        Plots.scatter!(avg_temps, true_A, label="True A", c=:lightsteelblue2)
        plot_epoch = Plots.plot!(-23:1:0, pred_A, label="Predicted A", 
                            xlabel="Long-term air temperature (°C)", yticks=yticks,
                            ylabel="A", ylims=(0.0,maxA[]), lw = 3, c=:dodgerblue4,
                            legend=:topleft)
        if !isdir(joinpath(training_path,"png")) || !isdir(joinpath(training_path,"pdf"))
            mkpath(joinpath(training_path,"png"))
            mkpath(joinpath(training_path,"pdf"))
        end
        # Plots.savefig(plot_epoch,joinpath(root_plots,"training","epoch$current_epoch.svg"))
        Plots.savefig(plot_epoch,joinpath(training_path,"png","epoch$(current_epoch-1).png"))
        Plots.savefig(plot_epoch,joinpath(training_path,"pdf","epoch$(current_epoch-1).pdf"))

        plot_loss = Plots.plot(loss_history, label="", xlabel="Epoch", yaxis=:log10,
                    ylabel="Loss (V)", lw = 3, c=:darkslategray3)
        Plots.savefig(plot_loss,joinpath(training_path,"png","loss$(current_epoch-1).png"))
        Plots.savefig(plot_loss,joinpath(training_path,"pdf","loss$(current_epoch-1).pdf"))
    end
    # Plots.savefig(plot_epoch,joinpath(root_plots,"training","epoch$current_epoch.svg"))
    Plots.savefig(plot_epoch,joinpath(training_path,"png","epoch$(current_epoch).png"))
    Plots.savefig(plot_epoch,joinpath(training_path,"pdf","epoch$(current_epoch).pdf"))
    global current_epoch += 1
    push!(loss_history, l)

    plot_loss = Plots.plot(loss_history, label="", xlabel="Epoch", yaxis=:log10,
                ylabel="Loss (V)", lw = 3, c=:darkslategray3)
    Plots.savefig(plot_loss,joinpath(training_path,"png","loss$(current_epoch).png"))
    Plots.savefig(plot_loss,joinpath(training_path,"pdf","loss$(current_epoch).pdf"))
    
    false
end

"""
    loss_iceflow(θ, UA_f, gdirs_climate, context_batches, gdir_refs::Dict{String, Any}, UDE_settings)  

Loss function based on glacier ice velocities and/or ice thickness
"""
function loss_iceflow(θ, UA_f, gdirs_climate, context_batches, gdir_refs, UDE_settings) 
    H_V_preds = predict_iceflow(θ, UA_f, gdirs_climate, context_batches, UDE_settings)
    # Compute loss function for the full batch
    l_Vx, l_Vy, l_H = 0.0, 0.0, 0.0
    for i in 1:length(H_V_preds)
        # Get ice thickness from the reference dataset
        H_ref = gdir_refs[i]["H"]
        # Get ice velocities for the reference dataset
        Vx_ref = gdir_refs[i]["Vx"]
        Vy_ref = gdir_refs[i]["Vy"]
        # Get ice thickness from the UDE predictions
        H = H_V_preds[i][1]
        # Get ice velocities prediction from the UDE
        V̄x_pred = H_V_preds[i][2]
        V̄y_pred = H_V_preds[i][3]

        if scale_loss[]
            normH = mean(H_ref.^2.0f0)^0.5f0
            # normV = mean(Vx_ref.^2.0f0 .+ Vy_ref.^2.0f0)^0.5f0
            normV = maximum(Vx_ref.^2.0f0 .+ Vy_ref.^2.0f0)^0.5f0
            l_H_loc = Flux.Losses.mse(H, H_ref; agg=mean) 
            l_V_loc = Flux.Losses.mse(V̄x_pred, Vx_ref; agg=mean) + Flux.Losses.mse(V̄y_pred, Vy_ref; agg=mean)
            l_H += normH^(-2.0f0) * l_H_loc
            # l_V += normV^(-1.0f0) * l_V_loc
            l_V += normV * log(l_V_loc)
        else
            l_H += Flux.Losses.mse(H[H_ref .!= 0.0], H_ref[H_ref.!= 0.0]; agg=mean) 
            l_Vx += Flux.Losses.mse(V̄x_pred[Vx_ref .!= 0.0], Vx_ref[Vx_ref.!= 0.0]; agg=mean)
            l_Vy += Flux.Losses.mse(V̄y_pred[Vy_ref .!= 0.0], Vy_ref[Vy_ref.!= 0.0]; agg=mean)
            l_V += l_Vx + l_Vy
        end
    end

    @assert (loss_type[] == "H" || loss_type[] == "V" || loss_type[] == "HV") "Invalid loss_type. Needs to be 'H', 'V' or 'HV'"
    if loss_type[] == "H"
        l_tot = l_H/length(gdir_refs)
    elseif loss_type[] == "V"
        l_tot = l_V/length(gdir_refs) 
    elseif loss_type[] == "HV"
        l_tot = (l_V + l_H)/length(gdir_refs)
    end
    return l_tot, UA_f[1]
end

"""
    predict_iceflow(θ, UA_f, gdirs_climate, context_batches, UDE_settings)

Makes a prediction of glacier evolution with the UDE for a given temperature series in different batches
"""
function predict_iceflow(θ, UA_f, gdirs_climate_batches, context_batches, UDE_settings)
    # Train UDE in parallel
    # UA_f and UDE_settings need to be passed as scalars since they were transformed to Vectors for the batches
    H_V_pred = map((context, gdirs_climate_batch) -> batch_iceflow_UDE(θ, UA_f[1], context, gdirs_climate_batch, UDE_settings[1]), context_batches, gdirs_climate_batches)
    return H_V_pred
end


"""
    batch_iceflow_UDE(θ, UA_f, context, longterm_temps_batch, UDE_settings) 

Solve the Shallow Ice Approximation iceflow UDE for a given temperature series batch
"""
function batch_iceflow_UDE(θ, UA_f, context, gdirs_climate_batch, UDE_settings) 
    # Retrieve long-term temperature series
    # context = (B, H₀, H, Vxy_obs, nxy, Δxy, tspan)
    H = context[2]
    S = context[9]
    tspan = context[6]
    longterm_temps_batch = gdirs_climate_batch[3]

    # Callback  
    if use_MB[] 
        # Define stop times every one month
        tmin_int = Int(tspan[1])
        tmax_int = Int(tspan[2])+1
        tstops = range(tmin_int+1.0f0/12.0f0, tmax_int, step=1/12.0f0) |> collect
        tstops = filter(x->( (Int(tspan[1])<x) & (x<=Int(tspan[2])) ), tstops)

        function stop_condition(u,t,integrator) 
            t in tstops
        end
        function action!(integrator)
            year = floor(Int, integrator.t[end])  
            MB = compute_MB_matrix(context, S, integrator.u, year)
            # since the mass balance is anual, we need to divide per month
            integrator.u .+= MB / 12.0f0
        end
        cb_MB = DiscreteCallback(stop_condition, action!)
    else
        tstops = []
        cb_MB = DiscreteCallback((u,t,integrator)->false, nothing)
    end
    
    @show typeof(θ)
    @show typeof(context)
    iceflow_UDE_batch(H, θ, t) = iceflow_NN(H, θ, t, UA_f, context, longterm_temps_batch) # closure
    iceflow_prob = ODEProblem(iceflow_UDE_batch, H, tspan, tstops=tstops, θ)
    iceflow_sol = solve(iceflow_prob, 
                        UDE_settings["solver"], 
                        callback=cb_MB,
                        tstops=tstops,
                        u0=H, 
                        p=θ,
                        sensealg=UDE_settings["sensealg"],
                        reltol=UDE_settings["reltol"], 
                        save_everystep=true, # has to be true in order to Zygote to work.  
                        progress=true, 
                        progress_steps=100)
    # @show iceflow_sol.destats
    # Get ice velocities from the UDE predictions
    H_pred = iceflow_sol.u[end]
    V̄x_pred, V̄y_pred = avg_surface_V(context, H_pred, mean(longterm_temps_batch), "UDE", θ, UA_f) # Average velocity with average temperature
    H_V_pred = (H_pred, V̄x_pred, V̄y_pred)
    return H_V_pred
end

"""
    iceflow!(dH, H, context,t)

Runs a single time step of the iceflow PDE model in-place
"""
function iceflow!(dH, H, context,t)
    # First, enforce values to be positive
    H[H.<0.0] .= H[H.<0.0] .* 0.0
    # Then, clip values if they get too high due to solver instabilities
    H₀ = context.x[21]
    H[H.>(2.0 * maximum(H₀))] .= 2.0 * maximum(H₀)
    # Unpack parameters
    #A, B, S, dSdx, dSdy, D, temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year 
    current_year = context.x[18]
    A = context.x[1]
    t₁ = context.x[22][end]
    A_noise = context.x[23]
    climate_years = context.x[30]

    # Get current year for MB and ELA
    year = floor(Int, t) 
    if year != current_year && year <= t₁ 
        temp = context.x[7][year .== climate_years]
        A .= A_fake(temp, A_noise, noise)
        current_year .= year
    end

    # Compute the Shallow Ice Approximation in a staggered grid
    SIA!(dH, H, context)
end    

"""
    iceflow_NN(H, θ, t, UA_f, context, temps)

Runs a single time step of the iceflow UDE model 
"""
function iceflow_NN(H, θ, t, UA_f, context, temps)
    t₁ = context[6][end]
    H₀ = context[2]
    H_buf = Buffer(H)
    @views H_buf .= ifelse.(H.<0.0, 0.0, H) # prevent values from going negative
    @views H_buf .= ifelse.(H.>(1.5 * maximum(H₀)), 1.5 * maximum(H₀), H) # prevent values from becoming too large
    H = copy(H_buf)
    B = context[1]
    S = B .+ H
    climate_years = context[11]

    @show t

    year = floor(Int, t) 
    temp = temps[year .== climate_years]
    A = predict_A̅(UA_f, θ, temp)[1]
    # Compute the Shallow Ice Approximation in a staggered grid
    if typeof(A) <: AbstractFloat
        dH = SIA(H, A, context) 
    else
        # When including MB, Zygote returns 
        dH = SIA(H, A.value, context) 
    end
    # dH = SIA(H, A, context) 

    return dH
end  

"""
    SIA!(dH, H, context)

Compute an in-place step of the Shallow Ice Approximation PDE in a forward model
"""
function SIA!(dH, H, context)
    # Retrieve parameters
    #[A], B, S, dSdx, dSdy, D, copy(temp_series[1]), dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, [current_year], nxy, Δxy
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
    Δx = context.x[20][1]
    Δy = context.x[20][2]
    MB = context.x[25]
    Γ = context.x[27]

    # Update glacier surface altimetry
    S .= B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx .= diff_x(S) ./ Δx
    dSdy .= diff_y(S) ./ Δy
    ∇S .= (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n[] - 1)/2) 

    Γ .= 2.0 * A * (ρ[] * g[])^n[] / (n[]+2) # 1 / m^3 s 
    D .= Γ .* avg(H).^(n[] + 2) .* ∇S

    # Compute flux components
    @views dSdx_edges .= diff_x(S[:,2:end - 1]) ./ Δx
    @views dSdy_edges .= diff_y(S[2:end - 1,:]) ./ Δy
    Fx .= .-avg_y(D) .* dSdx_edges
    Fy .= .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    inn(dH) .= .-(diff_x(Fx) ./ Δx .+ diff_y(Fy) ./ Δy) 
end

"""
    SIA(H, A, context)

Compute a step of the Shallow Ice Approximation UDE in a forward model. Allocates memory.
"""
function SIA(H, A, context)
    # Retrieve parameters
    # context = (B, H₀, H, Vxy_obs, nxy, Δxy, tspan)
    B = context[1]
    Δx = context[6][1]
    Δy = context[6][2]

    # Update glacier surface altimetry
    S = B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx = diff_x(S) ./ Δx
    dSdy = diff_y(S) ./ Δy
    ∇S = (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n[] - 1)/2) 

    Γ = 2.0 * A * (ρ[] * g[])^n[] / (n[]+2) # 1 / m^3 s 
    D = Γ .* avg(H).^(n[] + 2) .* ∇S

    # Compute flux components
    @views dSdx_edges = diff_x(S[:,2:end - 1]) ./ Δx
    @views dSdy_edges = diff_y(S[2:end - 1,:]) ./ Δy
    Fx = .-avg_y(D) .* dSdx_edges
    Fy = .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    @tullio dH[i,j] := -(diff_x(Fx)[pad(i-1,1,1),pad(j-1,1,1)] / Δx + diff_y(Fy)[pad(i-1,1,1),pad(j-1,1,1)] / Δy) # MB to be added here 

    return dH
end

"""
    SIA(H, V::Matrix, context)

Compute a step of the Shallow Ice Approximation, constrained by surface velocity observations. Allocates memory.
"""
function SIA(H, T, context, years, θ, UD_f, target)
    @assert (target == "A" || target == "D") "Functional inversion target needs to be either A or D!"
    # Retrieve parameters
    # context = (nxy, Δxy, tspan, rgi_id, S, V)
    Δx = context[2][1]
    Δy = context[2][2]
    S = context[5] # TODO: update this to Millan et al.(2022) DEM

    if H==0.0 # Retrieve H from context if Glathida thickness is not present 
        H = context[7]
    end

    # Get long term temperature for the Millan et al.(2022) dataset
    temp = T[years .== 2017]

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx = diff_x(S) ./ Δx
    dSdy = diff_y(S) ./ Δy
    ∇S = (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n[] - 1)/2) 
    
    if target == "D"
        X = build_D_features(H, temp, ∇S)
        D = predict_diffusivity(UD_f, θ, X)
    elseif target == "A"
        A = predict_A̅(UD_f, θ, temp)
        Γ = 2.0f0 * A * (ρ[] * g[])^n[] / (n[]+2.0f0) # 1 / m^3 s 
        D = Γ .* inn1(H).^(n[] + 2.0f0) .* ∇S
    end
    V = D .* abs.(∇S[inn1(H) .!= 0.0])
    return V
end

"""
    avg_surface_V(H, B, temp)

Computes the average ice surface velocity for a given input temperature
"""
function avg_surface_V(context, H, temp, sim, θ=[], UA_f=[])
    # context = (B, H₀, H, nxy, Δxy)
    B, H₀, Δx, Δy, A_noise = retrieve_context(context)

    # We compute the initial and final surface velocity and average them
    # TODO: Add more H datapoints to better interpolate this
    Vx, Vy = surface_V(H, H₀, B, Δx, Δy, temp, sim, A_noise, θ, UA_f)

    return Vx, Vy
        
end

"""
    avg_surface_V(H, B, temp)

Computes the ice surface velocity for a given input temperature
"""
function surface_V(H, H₀, B, Δx, Δy, temp, sim, A_noise, θ=[], UA_f=[])
    # Update glacier surface altimetry
    S = B .+ (H₀ .+ H)./2.0f0 # Use average ice thickness for the simulated period

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx = diff_x(S) / Δx
    dSdy = diff_y(S) / Δy
    ∇S = (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n[] - 1)/2) 
    
    @assert (sim == "UDE" || sim == "PDE") "Wrong type of simulation. Needs to be 'UDE' or 'PDE'."
    if sim == "UDE"
        A = predict_A̅(UA_f, θ, [temp]) 
    elseif sim == "PDE"
        A = A_fake(temp, A_noise, noise)
    end
    Γꜛ = 2.0f0 * A * (ρ[] * g[])^n[] / (n[]+1) # surface stress (not average)  # 1 / m^3 s 
    D = Γꜛ .* avg(H).^(n[] + 1) .* ∇S
    
    # Compute averaged surface velocities
    Vx = - D .* avg_y(dSdx)
    Vy = - D .* avg_x(dSdy)

    return Vx, Vy
        
end
