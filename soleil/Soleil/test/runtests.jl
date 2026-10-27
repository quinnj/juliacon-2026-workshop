using AbstractStores
using Dates
using Encid
using Harbor
using HTTP
using JSON
using JWTs
using NATS
using OAuth
using OpenAPI
using Servo
using Solar
using Soleil
using Tempus
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

function post_json(url, body; token=nothing)
    headers = ["Content-Type" => "application/json"]
    token === nothing || push!(headers, "Authorization" => "Bearer $token")
    return HTTP.post(url, headers, JSON.json(body); status_exception=false)
end

# Like client_demo.jl: generate a client from the running service. This runs
# before the tests, so they can call the module the include defines. Port 0
# picks a free port.
directory = mktempdir()
configs = Dict{String,Any}("port" => 0, "state" => Dict{String,Any}("path" => directory))
empty!(Servo.CONFIG)
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

    @testset "file state" begin
        mktempdir() do directory
            backend = test_persistence(Dict{String,Any}("path" => directory))
            stored_keys = collect(keys(backend))
            @test "soleil/meta/jwt-private-key" in stored_keys
            @test any(startswith("oauth/access/"), stored_keys)
            @test !any(contains("persistent@example.com"), stored_keys)
        end
    end

    @testset "weather advisory matching and expiry" begin
        state = Soleil._new_application_state()
        password = "correct horse battery staple"
        utah = Soleil._create_account!(state, Soleil.Credentials("utah@example.com", password))
        london = Soleil._create_account!(state, Soleil.Credentials("london@example.com", password))
        Soleil._create_summary!(state, utah.id, Soleil.SimulationRequest(40.76, -111.89, 2026, 8.0))
        Soleil._create_summary!(state, london.id, Soleil.SimulationRequest(51.51, -0.13, 2026, 8.0))
        now = Dates.now(UTC)
        utah_box = Soleil.GeoBounds(37.0, -114.1, 42.1, -109.0)
        advisory = Soleil.WeatherAdvisory("utah-hail", "hail", "severe", "Large hail", utah_box, now - Minute(5), now + Hour(1))

        @test Soleil._apply_weather_advisory!(state, advisory) == 1
        @test only(Soleil._weather_status(state, utah.id).advisories).id == advisory.id
        @test isempty(Soleil._weather_status(state, london.id).advisories)
        # Applying the same advisory again replaces it.
        @test Soleil._apply_weather_advisory!(state, advisory) == 1
        @test length(Soleil._weather_status(state, utah.id).advisories) == 1

        date_line = Soleil.GeoBounds(37.0, 170.0, 42.1, -170.0)
        crossing = Soleil.WeatherAdvisory("wind", "wind", "moderate", "Wind", date_line, now, now + Hour(1))
        @test_throws ArgumentError Soleil._validate_weather_advisory(crossing)

        @test Soleil._expire_weather_advisories!(state, advisory.ends_at) == 1
        @test isempty(Soleil._weather_status(state, utah.id).advisories)

        # Moving a summary drops the advisories matched to its old location.
        Soleil._apply_weather_advisory!(state, advisory)
        Soleil._update_summary!(state, utah.id, Soleil.SimulationRequest(51.51, -0.13, 2026, 8.0))
        @test isempty(Soleil._weather_status(state, utah.id).advisories)
        @test Soleil._apply_weather_advisory!(state, advisory) == 0
    end

    @testset "weather events through NATS and Tempus" begin
        if !docker_available()
            @test_skip "Docker is not available"
        else
            Harbor.with_container(
                "nats";
                tag="2.10.18",
                ports=Dict(4222 => 0),
                command=["--jetstream"],
                wait_strategy=(port=4222,),
                wait_timeout=120.0,
            ) do container
                mktempdir() do directory
                    secret = "integration-weather-secret"
                    events = Dict{String,Any}(
                        "enabled" => true,
                        "webhook_secret" => secret,
                        "cleanup_schedule" => "* * * * * *",
                        "logging" => false,
                        "nats" => Dict{String,Any}("url" => "nats://127.0.0.1:$(Harbor.host_port(container, 4222))"),
                    )
                    configs = Dict{String,Any}(
                        "port" => 0,
                        "state" => Dict{String,Any}("path" => directory),
                        "events" => events,
                    )
                    empty!(Servo.CONFIG)
                    server = Soleil.run!(; host="127.0.0.1", configs, accesslog=false, log=false)
                    try
                        base = "http://127.0.0.1:$(Servo.port(server))"
                        credentials = Soleil.Credentials("utah@example.com", "correct horse battery staple")
                        post_json("$base/v1/accounts", credentials)
                        login = JSON.parse(String(post_json("$base/v1/login", credentials).body), Soleil.LoginResponse)
                        input = Soleil.SimulationRequest(40.76, -111.89, 2026, 8.0)
                        @test post_json("$base/v1/simulate/$(login.user_id)", input; token=login.access_token).status == 200
                        weather() = JSON.parse(
                            String(HTTP.get("$base/v1/weather/$(login.user_id)", ["Authorization" => "Bearer $(login.access_token)"]).body),
                            Soleil.WeatherStatus,
                        )

                        now = trunc(Dates.now(UTC), Second)
                        utah_box = Soleil.GeoBounds(37.0, -114.1, 42.1, -109.0)
                        advisory = Soleil.WeatherAdvisory("utah-hail", "hail", "severe", "Large hail", utah_box, now - Minute(1), now + Second(8))
                        webhook = "$base/v1/webhooks/weather-advisories"
                        @test post_json(webhook, advisory).status == 401
                        crossing = Soleil.WeatherAdvisory("wind", "wind", "moderate", "Wind", Soleil.GeoBounds(37.0, 170.0, 42.1, -170.0), now, now + Hour(1))
                        @test post_json(webhook, crossing; token=secret).status == 400

                        accepted = post_json(webhook, advisory; token=secret)
                        @test accepted.status == 200
                        receipt = JSON.parse(String(accepted.body), Soleil.WeatherAdvisoryReceipt)
                        @test receipt.event_id == advisory.id
                        @test receipt.stream_sequence > 0
                        @test !receipt.duplicate
                        # The worker applies the advisory once JetStream delivers it.
                        @test timedwait(() -> length(weather().advisories) == 1, 10; pollint=0.1) == :ok

                        # JetStream recognizes a retried webhook by the advisory id.
                        duplicate = JSON.parse(String(post_json(webhook, advisory; token=secret).body), Soleil.WeatherAdvisoryReceipt)
                        @test duplicate.duplicate
                        @test duplicate.stream_sequence == receipt.stream_sequence

                        # The Tempus job, running every second, removes it after `ends_at`.
                        @test timedwait(() -> isempty(weather().advisories), 15; pollint=0.1) == :ok
                        history = Tempus.getNMostRecentJobExecutions(server.events.scheduler.store, Soleil.WEATHER_CLEANUP_JOB, 10)
                        @test !isempty(history)
                        @test all(execution -> execution.succeeded, history)
                        stream = NATS.JetStream.stream_info(server.events.connection, Soleil.WEATHER_STREAM; timeout=10)
                        @test Int(stream.state.messages) == 1

                        # Tempus keeps its job and history in the same backend as Soleil.
                        stored_keys = collect(keys(AbstractStores.FileStore(directory; codec=AbstractStores.JSONCodec())))
                        @test any(startswith("tempus/jobs/"), stored_keys)
                        @test any(startswith("tempus/executions/"), stored_keys)
                    finally
                        close(server)
                    end
                end
            end
        end
    end
end
