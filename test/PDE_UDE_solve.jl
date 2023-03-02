

function pde_solve_test(atol; MB=false)
    println("PDE solving with MB = $MB")
    working_dir = joinpath(homedir(), "Python/ODINN_tests")
    oggm_config(working_dir)
    ODINN.noise[] = false
    ODINN.set_use_MB(false)

    # @eval ODINN pde_A_values = []
    # @eval ODINN ude_A_values = []

    ## Retrieving gdirs and climate for the following glaciers  
    rgi_ids = ["RGI60-11.03638", "RGI60-11.01450", "RGI60-08.00213", "RGI60-04.04351", "RGI60-01.02170",
    "RGI60-02.05098", "RGI60-01.01104", "RGI60-01.09162", "RGI60-01.00570", "RGI60-04.07051",                	
    "RGI60-07.00274", "RGI60-07.01323",  "RGI60-01.17316"]

    # Load reference values for the simulation
    PDE_refs = load(joinpath(ODINN.root_dir, "test/data/PDE_refs.jld2"))["PDE_preds"]

    gdirs = init_gdirs(rgi_ids)
    tspan = (2010.0, 2015.0) # period in years for simulation

    # Run the forward PDE simulation
    PDE_preds = @time generate_ref_dataset(gdirs, tspan)

    # Run one epoch of the UDE training
    θ = zeros(10) # dummy data for the NN
    UA_f = zeros(10)
    UDE_settings, train_settings = ODINN.get_default_training_settings!(gdirs)
    context_batches = ODINN.get_UDE_context(gdirs, tspan; testmode=true)
    H_V_preds = @time ODINN.predict_iceflow(θ, UA_f, gdirs, context_batches, UDE_settings) # Array{(H_pred, V̄x_pred, V̄y_pred, rgi_id)}

    let PDE_refs=PDE_refs, H_V_preds=H_V_preds
    for PDE_pred in PDE_preds
        let PDE_refs=PDE_refs, test_ref, H_V_preds=H_V_preds, UDE_pred, rgi_id
        for (PDE_ref, H_V_pred) in zip(PDE_refs, H_V_preds)
            rgi_id = PDE_pred["RGI_ID"]
            if rgi_id == PDE_ref["RGI_ID"]
                test_ref = PDE_ref
            end

            if rgi_id == H_V_pred[4]
                UDE_pred = H_V_pred
            end
        end

        ##############################
        #### Make plots of errors ####
        ##############################
        test_plot_path = joinpath(ODINN.root_dir, "test/plots")
        if !isdir(test_plot_path)
            mkdir(test_plot_path)
        end
        vtol = 10.0*atol # a little extra tolerance for UDE surface velocities
        ### PDE ###
        ODINN.plot_test_error(PDE_pred, test_ref, "H", rgi_id, atol)
        ODINN.plot_test_error(PDE_pred, test_ref, "Vx", rgi_id, atol)
        ODINN.plot_test_error(PDE_pred, test_ref, "Vy", rgi_id, atol)
        ### UDE ###
        ODINN.plot_test_error(UDE_pred, test_ref, "H", rgi_id, atol)
        ODINN.plot_test_error(UDE_pred, test_ref, "Vx", rgi_id, vtol)
        ODINN.plot_test_error(UDE_pred, test_ref, "Vy", rgi_id, vtol)

        # Test that the PDE simulations are correct
        @test isapprox(PDE_pred["H"], test_ref["H"], atol=atol)
        @test isapprox(PDE_pred["Vx"], test_ref["Vx"], atol=atol)
        @test isapprox(PDE_pred["Vy"], test_ref["Vy"], atol=atol)
        # Test that the UDE simulations are correct
        @test isapprox(UDE_pred[1], test_ref["H"], atol=atol)
        @test isapprox(UDE_pred[2], test_ref["Vx"], atol=vtol) 
        @test isapprox(UDE_pred[3], test_ref["Vy"], atol=vtol)
        end
    end
    end
end

pde_solve_test(atol; MB=false)
pde_solve_test(atol; MB=true)
