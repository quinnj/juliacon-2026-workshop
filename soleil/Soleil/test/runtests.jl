using AbstractStores
using Encid
using Harbor
using HTTP
using JSON
using JWTs
using OAuth
using OpenAPI
using Servo
using Solar
using Soleil
using Test

docker_available() = Sys.which("docker") !== nothing && success(`docker info`)

# The backend Soleil opens for these `state` settings.
function configured_backend(settings)
    empty!(Servo.CONFIG)
    Servo.loadconfig!(; configs=Dict{String,Any}("state" => settings), log=false)
    return Soleil._configured_state_backend(nothing)
end

# Everything a state writes, the signing key included, lives in its backend: a
# second state over the same storage accepts the first state's token and finds
# its summary.
function test_persistence(settings)
    credentials = Soleil.Credentials("persistent@example.com", "correct horse battery staple")
    original = Soleil._new_application_state(configured_backend(settings))
    account = Soleil._create_account!(original, credentials)
    token = Soleil._login!(original, credentials).access_token
    input = Soleil.SimulationRequest(40.76, -111.89, 2026, 8.0)
    stored = Soleil._create_summary!(original, account.id, input)

    reopened = Soleil._new_application_state(configured_backend(settings))
    context = Servo.authenticatebearer(Soleil.SoleilTokenValidator(reopened), token, nothing)
    @test context isa Soleil.AuthContext
    @test context.user.id == account.id
    restored = Soleil._get_summary(reopened, account.id)
    @test restored.summary.estimated_annual_energy_kwh == stored.summary.estimated_annual_energy_kwh
    @test restored.summary.best_day == stored.summary.best_day
    return original.backend
end

# Like client_demo.jl: generate a client from the running service. This runs
# before the tests, so they can call the module the include defines. Port 0
# picks a free port.
configs = Dict{String,Any}("port" => 0, "state" => Dict{String,Any}("backend" => "memory"))
server = Soleil.run!(; host="127.0.0.1", configs, accesslog=false, log=false)
base = "http://127.0.0.1:$(Servo.port(server))"
document = OpenAPI.read("$base/openapi.json")
include_string(@__MODULE__, OpenAPI.client(document; name="SoleilClient"))
SoleilClient.server!(base)

# The status code of the ApiError `f` throws, or 0 when it succeeds.
function status(f)
    try
        f()
        return 0
    catch error
        error isa SoleilClient.ApiError || rethrow()
        return error.status
    end
end

@testset "Soleil" begin
    @testset "OpenAPI document" begin
        @test document["info"]["title"] == "Soleil API"
        @test haskey(document["paths"], "/v1/simulate/{latitude}/{longitude}")
        @test document["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
        @test !haskey(document["paths"]["/v1/accounts"]["post"], "security")
        @test haskey(document["paths"]["/v1/simulate/{userId}"]["get"], "security")
        @test !haskey(document["components"]["schemas"]["Account"]["properties"], "password_digest")
    end

    @testset "public simulation" begin
        @test String(HTTP.get("$base/status").body) == "ok"
        kw = (; year=2026, system_capacity_kw=8.0, time_step_minutes=60)
        summary = SoleilClient.simulate(40.76, -111.89; kw...)
        expected = Solar.simulate(40.76, -111.89; kw...).summary
        @test summary isa SoleilClient.SolarSummary
        @test summary.estimated_annual_energy_kwh ≈ expected.estimated_annual_energy_kwh
        @test summary.best_day == expected.best_day
        # Solar's JSON tags round this field on the wire only.
        @test summary.average_daily_energy_kwh == round(expected.average_daily_energy_kwh; digits=2)
        @test summary.average_daily_energy_kwh != expected.average_daily_energy_kwh

        location = JSON.parse(JSON.json(Solar.Location(40.76, -111.89)))
        @test location["latitude_deg"] == 40.76
        @test !haskey(location, "latitude")
        @test !haskey(JSON.parse(JSON.json(Solar.simulate(0, 0).config)), "time_step_minutes")

        thrown = @test_throws SoleilClient.ApiError SoleilClient.simulate(95.0, -111.89)
        @test thrown.value.status == 400
        @test occursin("latitude", String(copy(thrown.value.body)))
    end

    @testset "accounts and stored summaries" begin
        credentials = SoleilClient.Credentials("solar@example.com", "correct horse battery staple")
        account = SoleilClient.create_account(credentials)
        @test status(() -> SoleilClient.create_account(credentials)) == 409
        @test status(() -> SoleilClient.login(SoleilClient.Credentials(credentials.email, "wrong"))) == 401
        token = SoleilClient.login(credentials)
        @test token.token_type == "Bearer"
        @test token.user_id == account.id

        # The generated client refuses a secured call until it has a token, and
        # the server answers an unauthenticated request with a 401.
        @test_throws ArgumentError SoleilClient.get_summary(account.id)
        @test HTTP.get("$base/v1/simulate/$(account.id)"; status_exception=false).status == 401

        SoleilClient.authorization!(token.access_token)
        input = SoleilClient.SimulationRequest(40.76, -111.89, 2026, 8.0)
        stored = SoleilClient.create_summary(account.id, input)
        expected = Solar.simulate(40.76, -111.89; year=2026, system_capacity_kw=8.0).summary
        @test stored.user_id == account.id
        @test stored.summary.estimated_annual_energy_kwh ≈ expected.estimated_annual_energy_kwh
        @test status(() -> SoleilClient.create_summary(account.id, input)) == 409
        @test SoleilClient.get_summary(account.id).updated_at == stored.updated_at

        # Another signed-in user cannot read this user's summary.
        other = SoleilClient.Credentials("other@example.com", credentials.password)
        SoleilClient.create_account(other)
        SoleilClient.authorization!(SoleilClient.login(other).access_token)
        @test status(() -> SoleilClient.get_summary(account.id)) == 403

        SoleilClient.authorization!(token.access_token)
        updated = SoleilClient.update_summary(account.id, SoleilClient.SimulationRequest(40.76, -111.89, 2026, 10.0))
        @test updated.system_capacity_kw == 10.0
        @test updated.summary.estimated_annual_energy_kwh > stored.summary.estimated_annual_energy_kwh
        @test SoleilClient.delete_summary(account.id) === nothing
        @test status(() -> SoleilClient.get_summary(account.id)) == 404

        SoleilClient.authorization!(token.access_token * "x")
        @test status(() -> SoleilClient.get_summary(account.id)) == 401
    end
    close(server)

    @testset "endpoints must declare auth" begin
        declaration = :(Servo.@GET "/v1/dummy" function dummy() end)
        thrown = @test_throws ArgumentError macroexpand(Soleil, declaration)
        @test occursin("does not declare an auth scheme", sprint(showerror, thrown.value))
    end

    @testset "default configuration" begin
        # PORT and PROFILE in the environment would override config.toml.
        profile = withenv("PORT" => nothing, "PROFILE" => nothing) do
            Servo.loadconfig!(; configdir=Soleil.DEFAULT_CONFIG_DIR, log=false)
        end
        @test profile == "local"
        @test Servo.config("port") == 9001
    end

    @testset "accounts and tokens" begin
        state = Soleil._new_application_state()
        credentials = Soleil.Credentials(" Solar@Example.com", "correct horse battery staple")
        account = Soleil._create_account!(state, credentials)
        @test account.email == "solar@example.com"
        @test all(in(Encid.Base58.ALPHABET), account.id)
        @test ncodeunits(account.id) <= 22
        thrown = @test_throws Servo.HTTPError Soleil._create_account!(state, credentials)
        @test thrown.value.status == 409

        # Equal passwords get different salts, so their digests differ too.
        other = Soleil._create_account!(state, Soleil.Credentials("other@example.com", credentials.password))
        @test state.users_by_id[account.id].password_salt != state.users_by_id[other.id].password_salt
        @test state.users_by_id[account.id].password_digest != state.users_by_id[other.id].password_digest

        thrown = @test_throws Servo.HTTPError Soleil._login!(state, Soleil.Credentials(credentials.email, "wrong"))
        @test thrown.value.status == 401
        token = Soleil._login!(state, credentials).access_token
        claims = JWTs.claims(JWTs.verify(state.token_verifier, token))
        @test claims.sub == account.id
        @test claims.email == account.email

        validator = Soleil.SoleilTokenValidator(state)
        context = Servo.authenticatebearer(validator, token, nothing)
        @test context isa Soleil.AuthContext
        @test context.user == account
        @test Servo.authenticatebearer(validator, token * "x", nothing) === nothing
        # A revoked token no longer authenticates, although its signature is valid.
        @test OAuth.revoke_access_token!(state.token_service, token)
        @test Servo.authenticatebearer(validator, token, nothing) === nothing
    end

    @testset "state backends" begin
        @test_throws ArgumentError configured_backend(Dict{String,Any}("backend" => "floppy"))

        @testset "file" begin
            mktempdir() do directory
                backend = test_persistence(Dict{String,Any}("backend" => "file", "path" => directory))
                stored_keys = collect(keys(backend))
                @test "soleil/meta/jwt-private-key" in stored_keys
                @test any(startswith("oauth/access/"), stored_keys)
                @test !any(contains("persistent@example.com"), stored_keys)
            end
        end

        @testset "sqlite" begin
            mktempdir() do directory
                path = joinpath(directory, "state.sqlite")
                test_persistence(Dict{String,Any}("backend" => "sqlite", "sqlite" => Dict{String,Any}("path" => path)))
            end
        end

        @testset "redis" begin
            if !docker_available()
                @test_skip "Docker is not available"
            else
                Harbor.with_container(
                    "redis";
                    tag="7",
                    ports=Dict(6379 => 0),
                    wait_strategy=(pattern="Ready to accept connections",),
                    wait_timeout=120.0,
                ) do container
                    redis = Dict{String,Any}("port" => Harbor.host_port(container, 6379))
                    test_persistence(Dict{String,Any}("backend" => "redis", "redis" => redis))
                end
            end
        end

        @testset "postgres" begin
            if !docker_available()
                @test_skip "Docker is not available"
            else
                Harbor.with_container(
                    "postgres";
                    tag="16",
                    ports=Dict(5432 => 0),
                    environment=Dict("POSTGRES_PASSWORD" => "postgres", "POSTGRES_DB" => "soleil"),
                    wait_strategy=(pattern=r"database system is ready to accept connections",),
                    wait_timeout=120.0,
                ) do container
                    postgres = Dict{String,Any}(
                        "port" => Harbor.host_port(container, 5432),
                        "password" => "postgres",
                        "database" => "soleil",
                    )
                    settings = Dict{String,Any}("backend" => "postgres", "postgres" => postgres)
                    # Postgres restarts once after initializing, so wait for a real connection.
                    retry(() -> configured_backend(settings); delays=fill(0.5, 60))()
                    test_persistence(settings)
                end
            end
        end
    end
end
