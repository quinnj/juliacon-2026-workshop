"""
Soleil serves the Solar package as a JSON web service, with user accounts and
stored summaries behind bearer-token authentication.

Start it with `Soleil.run()`, which blocks, or `Soleil.run!()`, which returns
the server. The service describes itself at `/openapi.json`, so a client can be
generated from the running server:

    doc = OpenAPI.read("http://127.0.0.1:9001/openapi.json")
    OpenAPI.client(doc; name="SoleilClient", path="SoleilClient.jl")
"""
module Soleil

using AbstractStores
using Dates
using Encid
using JSON # loads Servo's JSON response format
using JWTs
using OAuth
using OpenAPI
using Random
using SHA
using Servo
using Solar

const DEFAULT_CONFIG_DIR = normpath(joinpath(@__DIR__, "..", ".."))

include("summaries.jl")
include("auth.jl")

"""
    _register_endpoints!(router, state) -> router

Register Soleil's endpoints on `router`. They all share `state`.
"""
function _register_endpoints!(router::Servo.Router, state::ApplicationState)
    # Path segments bind the positional arguments and query parameters bind the
    # keywords, each converted to its declared type. `public` endpoints need no
    # authentication and get Servo's default rate limit.
    Servo.@GET router "/v1/simulate/{latitude}/{longitude}" public function simulate(
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

    # The request body binds the trailing positional argument.
    Servo.@POST router "/v1/accounts" public function create_account(
        credentials::Credentials,
    )::Account
        return _create_account!(state, credentials)
    end

    Servo.@POST router "/v1/login" public function login(
        credentials::Credentials,
    )::LoginResponse
        return _login!(state, credentials)
    end

    # These endpoints need a bearer token. `_owner` then checks that the
    # token's user owns the `{userId}` in the path.
    bearer = Servo.BearerAuth(SoleilTokenValidator(state))

    Servo.@POST router "/v1/simulate/{userId}" bearer function create_summary(
        userId::String,
        input::SimulationRequest,
    )::StoredSolarSummary
        return _create_summary!(state, _owner(userId), input)
    end

    Servo.@GET router "/v1/simulate/{userId}" bearer function get_summary(
        userId::String,
    )::StoredSolarSummary
        return _get_summary(state, _owner(userId))
    end

    Servo.@PUT router "/v1/simulate/{userId}" bearer function update_summary(
        userId::String,
        input::SimulationRequest,
    )::StoredSolarSummary
        return _update_summary!(state, _owner(userId), input)
    end

    Servo.@DELETE router "/v1/simulate/{userId}" bearer function delete_summary(
        userId::String,
    )::Nothing
        return _delete_summary!(state, _owner(userId))
    end

    # Describe the registered endpoints as OpenAPI 3.2 at /openapi.json.
    OpenAPI.register!(router; title="Soleil API", version=string(pkgversion(Soleil)))
    return router
end

"""
    Soleil.run!(profile=""; configdir=DEFAULT_CONFIG_DIR, kw...) -> server

Start Soleil without blocking. Servo loads `config.toml` and the profile's
overrides from `configdir`, the application directory by default; then Soleil
creates its state and endpoints and Servo starts listening. The `local` profile
enables CORS. Other keywords go to `Servo.run!`.
"""
function run!(profile::AbstractString=""; configdir=DEFAULT_CONFIG_DIR, kw...)
    router = Servo.Router()
    setup() = (_register_endpoints!(router, _new_application_state()); nothing)
    return Servo.run!("Soleil", profile; configdir, router, setup, kw...)
end

"""
    Soleil.run(profile=""; configdir=DEFAULT_CONFIG_DIR, kw...)

Like [`run!`](@ref), but block until interrupted, then shut down cleanly. This
is the deployment entry point: `julia -e 'using Soleil; Soleil.run()'`.
"""
function run(args...; kw...)
    server = run!(args...; kw...)
    try
        wait(server)
    catch error
        error isa InterruptException || rethrow()
    finally
        close(server)
    end
    return nothing
end

end # module
