# soleil

The Julia environment for the Soleil project. [`Solar`](Solar/) and
[`Soleil`](Soleil/) are local packages that share this directory's
`Manifest.toml`.

Start Julia in this environment:

```sh
julia --project=soleil
```

Then run a one-year solar simulation:

```julia
using Solar

simulation = Solar.simulate(40.39, -111.85; year=2026)
```

`simulation.daily` holds every simulated day and `simulation.summary` the
totals. The [Solar README](Solar/README.md) covers the API and the model.

## The service

`Soleil` serves Solar as a JSON API with
[Servo](https://github.com/JuliaServices/Servo.jl): a public
`GET /v1/simulate/{latitude}/{longitude}` endpoint, plus an OpenAPI description
of the API at `/openapi.json`. Start it from the repository root:

```sh
julia --project=soleil soleil/server_demo.jl
```

The server reads [`config.toml`](config.toml), which sets `port = 9001`. A
`PORT` environment variable or a `--port=...` argument overrides it.

In a second terminal, generate a typed client from the running service and call
it:

```sh
julia --project=soleil soleil/client_demo.jl
```

[client_demo.jl](client_demo.jl) reads `/openapi.json` and writes
`SoleilClient.jl`: a function per endpoint and a struct per schema. It then
calls `SoleilClient.simulate(40.76, -111.89; system_capacity_kw=8.0)`, which
returns a typed `SolarSummary`, and shows a validation error coming back as a
typed `SoleilClient.ApiError`. `SoleilClient.jl` is regenerated on every run.

## Tests

From the repository root:

```sh
julia --project=soleil -e 'using Pkg; Pkg.test(["Solar", "Soleil"])'
```
