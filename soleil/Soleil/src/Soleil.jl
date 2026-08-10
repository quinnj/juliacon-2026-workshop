"""
Soleil serves the Solar package as a JSON web service.

Start it with `Soleil.run()`, which blocks, or `Soleil.run!()`, which returns
the server. The service describes itself at `/openapi.json`, so a client can be
generated from the running server:

    doc = OpenAPI.read("http://127.0.0.1:9001/openapi.json")
    OpenAPI.client(doc; name="SoleilClient", path="SoleilClient.jl")
"""
module Soleil

using Dates
using JSON # loads Servo's JSON response format
using OpenAPI
using Servo
using Solar

const DEFAULT_CONFIG_DIR = normpath(joinpath(@__DIR__, "..", ".."))

# Endpoints are runtime state, so they register when Soleil loads. `Servo.@init`
# defines `__init__` and skips it while Soleil precompiles.
Servo.@init begin
    # Path segments bind the positional arguments and query parameters bind the
    # keywords, each converted to its declared type. `public` endpoints need no
    # authentication and get Servo's default rate limit.
    Servo.@GET "/v1/simulate/{latitude}/{longitude}" public function simulate(
        latitude::Float64,
        longitude::Float64;
        year::Int=Dates.year(Dates.today()),
        utc_offset_hours::Float64=longitude / 15,
        panel_tilt_deg::Float64=abs(latitude),
        panel_azimuth_deg::Float64=180.0,
        system_capacity_kw::Float64=6.0,
        performance_ratio::Float64=0.8,
        atmospheric_transmittance::Float64=0.72,
        ground_albedo::Float64=0.2,
        time_step_minutes::Int=15,
    )
        # Solar throws ArgumentError for invalid input; Servo answers it with a 400.
        simulation = Solar.simulate(
            latitude,
            longitude;
            year,
            utc_offset_hours,
            panel_tilt_deg,
            panel_azimuth_deg,
            system_capacity_kw,
            performance_ratio,
            atmospheric_transmittance,
            ground_albedo,
            time_step_minutes,
        )
        return simulation.summary
    end

    # Describe the registered endpoints as OpenAPI 3.2 at /openapi.json.
    OpenAPI.register!(
        Servo.ROUTER;
        title="Soleil API",
        version=string(pkgversion(Soleil)),
    )
end

"""
    Soleil.run!(profile=""; configdir=DEFAULT_CONFIG_DIR, kw...) -> server

Start Soleil without blocking. Servo loads `config.toml` and the profile's
overrides from `configdir`, the application directory by default. The `local`
profile enables CORS. Other keywords go to `Servo.run!`.
"""
run!(profile::AbstractString=""; configdir=DEFAULT_CONFIG_DIR, kw...) =
    Servo.run!("Soleil", profile; configdir, kw...)

"""
    Soleil.run(profile=""; configdir=DEFAULT_CONFIG_DIR, kw...)

Like [`run!`](@ref), but block until interrupted, then shut down cleanly. This
is the deployment entry point: `julia -e 'using Soleil; Soleil.run()'`.
"""
run(profile::AbstractString=""; configdir=DEFAULT_CONFIG_DIR, kw...) =
    Servo.run("Soleil", profile; configdir, kw...)

end # module
