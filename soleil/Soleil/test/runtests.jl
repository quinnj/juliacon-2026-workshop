using HTTP
using JSON
using OpenAPI
using Servo
using Solar
using Soleil
using Test

# Like client_demo.jl: generate a client from the running service. This runs
# before the tests, so they can call the module the include defines. Port 0
# picks a free port.
server = Soleil.run!(; host="127.0.0.1", configs=Dict("port" => 0), accesslog=false, log=false)
base = "http://127.0.0.1:$(Servo.port(server))"
document = OpenAPI.read("$base/openapi.json")
include_string(@__MODULE__, OpenAPI.client(document; name="SoleilClient"))
SoleilClient.server!(base)

@testset "Soleil" begin
    @testset "live service and generated client" begin
        @test String(HTTP.get("$base/status").body) == "ok"
        @test document["info"]["title"] == "Soleil API"
        @test haskey(document["paths"], "/v1/simulate/{latitude}/{longitude}")

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
end
