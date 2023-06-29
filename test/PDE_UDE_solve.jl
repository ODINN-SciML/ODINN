

function pde_solve_test(atol; MB=false, fast=true)
    println("PDE solving with MB = $MB")
    working_dir = joinpath(homedir(), "Python/ODINN_tests")
    
    params = Parameters(OGGM = OGGMparameters(working_dir=working_dir,
                                              multiprocessing=true,
                                              workers=2),
                        simulation = SimulationParameters(use_MB=MB,
                                                        velocities=false,
                                                        tspan=(2010.0, 2015.0))) 

    ## Retrieving gdirs and climate for the following glaciers
    ## Fast version includes less glacier to reduce the amount of downloaded files and computation time on GitHub CI  
    if fast
        rgi_ids = ["RGI60-11.03638", "RGI60-11.01450", "RGI60-08.00213", "RGI60-04.04351", "RGI60-01.02170"]
    else
        rgi_ids = ["RGI60-11.03638", "RGI60-11.01450", "RGI60-08.00213", "RGI60-04.04351", "RGI60-01.02170",
        "RGI60-02.05098", "RGI60-01.01104", "RGI60-01.09162", "RGI60-01.00570", "RGI60-04.07051",                	
        "RGI60-07.00274", "RGI60-07.01323",  "RGI60-01.17316"]
    end

    # Load reference values for the simulation
    if MB
        PDE_refs = load(joinpath(ODINN.root_dir, "test/data/PDE_refs_MB.jld2"))["PDE_preds"]
    else
        PDE_refs = load(joinpath(ODINN.root_dir, "test/data/PDE_refs_noMB.jld2"))["PDE_preds"]
    end

    model = Model(iceflow = SIA2Dmodel(parameters),
                  mass_balance = mass_balance = TImodel1(DDF=6.0/1000.0, acc_factor=1.2/1000.0),
                  machine_learning = NN(parameters))

    # We retrieve some glaciers for the simulation
    glaciers = initialize_glaciers(rgi_ids, params)

    # We create an ODINN prediction
    prediction = Prediction(model, glaciers, params)

    # We run the simulation
    @time run!(prediction)

    # /!\ Saves current run as reference values
    if MB
        jldsave(joinpath(ODINN.root_dir, "test/data/PDE_refs_MB.jld2"); prediction.results)
    else
        jldsave(joinpath(ODINN.root_dir, "test/data/PDE_refs_noMB.jld2"); prediction.results)
    end
    
    # # Run one epoch of the UDE training
    # θ = zeros(10) # dummy data for the NN
    # UA_f = zeros(10)
    # UDE_settings, train_settings = ODINN.get_default_training_settings!(gdirs)
    # context_batches = ODINN.get_UDE_context(gdirs, tspan; testmode=true, velocities=false)
    # H_V_preds = @time predict_iceflow(θ, UA_f, gdirs, context_batches, UDE_settings, mb_model) # Array{(H_pred, V̄x_pred, V̄y_pred, rgi_id)}



    let results=prediction.results
    for result in results
        let result=result, test_ref=nothing, UDE_pred=nothing
        for PDE_ref in PDE_refs
            if result.rgi_id == PDE_ref.rgi_id
                test_ref = PDE_ref
            end

            # if result.rgi_id == H_V_pred[4]
            #     UDE_pred = H_V_pred
            # end
        end

        ##############################
        #### Make plots of errors ####
        ##############################
        test_plot_path = joinpath(ODINN.root_dir, "test/plots")
        if !isdir(test_plot_path)
            mkdir(test_plot_path)
        end
        MB ? vtol = 30.0*atol : vtol = 12.0*atol # a little extra tolerance for UDE surface velocities
        ### PDE ###
        ODINN.plot_test_error(PDE_pred, test_ref, "H", rgi_id, atol, MB)
        ODINN.plot_test_error(PDE_pred, test_ref, "Vx", rgi_id, vtol, MB)
        ODINN.plot_test_error(PDE_pred, test_ref, "Vy", rgi_id, vtol, MB)
        ### UDE ###
        # ODINN.plot_test_error(UDE_pred, test_ref, "H", rgi_id, atol, MB)
        # ODINN.plot_test_error(UDE_pred, test_ref, "Vx", rgi_id, vtol, MB)
        # ODINN.plot_test_error(UDE_pred, test_ref, "Vy", rgi_id, vtol, MB)

        # Test that the PDE simulations are correct
        @test all(isapprox.(PDE_pred["H"], test_ref["H"], atol=atol))
        @test all(isapprox.(PDE_pred["Vx"], test_ref["Vx"], atol=vtol))
        @test all(isapprox.(PDE_pred["Vy"], test_ref["Vy"], atol=vtol))
        # Test that the UDE simulations are correct
        # @test all(isapprox.(UDE_pred[1], test_ref["H"], atol=atol))
        # @test all(isapprox.(UDE_pred[2], test_ref["Vx"], atol=vtol)) 
        # @test all(isapprox.(UDE_pred[3], test_ref["Vy"], atol=vtol))
        end # let
    end
    end
end
