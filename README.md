# ODINN: toy version
OGGM (Open Global Glacier Model) + DIfferential equation Neural Networks

<img src="https://github.com/ODINN-SciML/odinn_toy/blob/main/plots/ODINN_toy.png" width="300">

Toy model with raw implementation of glacier mass balance and ice dynamics Universal Differential Equations (UDEs). 

It uses neural networks and differential equations in order to combine mechanistic models describing glaciological processes (e.g. enhanced temperature-index model or the Shallow Ice Approximation) with machine learning. Neural networks are used to learn parts of the equations, which then can be interpreted in a mathematical form in order to update the original equation from the process. 

## Running the model

A demostration of our method is included in `scripts/Glacier_UDE`. The `Manifests.jl` includes all the requiered dependencies. If you are runnign this code from zero, you may need to install the libraries using `Pkg.instantiate()`. In case you want to include this package to the project manifest, you can also use `Pkg.resolve()` before instantiating the project. 