# Generate a typed client from the running service's OpenAPI document, then use it.
#
#   terminal 1:  julia --project=soleil soleil/server_demo.jl
#   terminal 2:  julia --project=soleil soleil/client_demo.jl [base-url]

using Dates
using HTTP # lets OpenAPI.read fetch a URL
using JSON
using OpenAPI

server_url = isempty(ARGS) ? "http://127.0.0.1:9001" : only(ARGS)

# Time the server's first and second simulation. A /status request first warms
# this client's own HTTP code, so the first timing is the server's.
HTTP.get("$server_url/status")
simulate_url = "$server_url/v1/simulate/40.76/-111.89?system_capacity_kw=8.0"
first_ms = round(1000 * @elapsed(HTTP.get(simulate_url)); digits=1)
second_ms = round(1000 * @elapsed(HTTP.get(simulate_url)); digits=1)
println("first simulate request: ", first_ms, " ms; second: ", second_ms, " ms")

# One function per endpoint and one struct per schema, written to SoleilClient.jl.
client_path = joinpath(@__DIR__, "SoleilClient.jl")
OpenAPI.client(OpenAPI.read("$server_url/openapi.json"); name="SoleilClient", path=client_path)
include(client_path)
SoleilClient.server!(server_url)

summary = SoleilClient.simulate(40.76, -111.89; system_capacity_kw=8.0)
best_month = argmax(month -> month.estimated_energy_kwh, summary.monthly)
println("simulate(40.76, -111.89; system_capacity_kw=8.0) -> ", typeof(summary))
println("  annual energy:  ", round(summary.estimated_annual_energy_kwh; digits=1), " kWh")
println("  daily average:  ", summary.average_daily_energy_kwh, " kWh")
println("  best day:       ", summary.best_day)
println("  best month:     ", best_month.month)

# The server's validation errors arrive as a typed ApiError.
try
    SoleilClient.simulate(95.0, -111.89)
catch error
    error isa SoleilClient.ApiError || rethrow()
    println("simulate(95.0, -111.89) -> ApiError ", error.status, ": ", JSON.parse(error.body).error.message)
end

# Create an account and trade its credentials for a bearer token.
credentials = SoleilClient.Credentials("solar-$(time_ns())@example.com", "correct horse battery staple")
account = SoleilClient.create_account(credentials)
token = SoleilClient.login(credentials)
println("created account ", account.id, "; its token expires in ", token.expires_in, " s")

# The client sends the token only to operations the OpenAPI document marks secured.
SoleilClient.authorization!(token.access_token)
stored = SoleilClient.create_summary(account.id, SoleilClient.SimulationRequest(40.76, -111.89, 2026, 8.0))
println("stored a summary: ", round(stored.summary.estimated_annual_energy_kwh; digits=1), " kWh")
println("read it back, updated at ", SoleilClient.get_summary(account.id).updated_at)
updated = SoleilClient.update_summary(account.id, SoleilClient.SimulationRequest(40.76, -111.89, 2026, 10.0))
println("updated to ", updated.system_capacity_kw, " kW: ", round(updated.summary.estimated_annual_energy_kwh; digits=1), " kWh")

# A weather provider posts an advisory with its own secret. The server returns
# once NATS JetStream has stored it; a background worker then tags the matching
# summaries, so poll for the tag.
now = Dates.now(Dates.UTC)
utah = SoleilClient.GeoBounds(37.0, -114.1, 42.1, -109.0)
advisory = SoleilClient.WeatherAdvisory(
    "utah-hail-$(time_ns())", "hail", "severe", "Large hail may damage exposed panels",
    utah, now - Dates.Minute(5), now + Dates.Hour(1),
)
SoleilClient.authorization!("soleil-demo-weather-secret")
receipt = SoleilClient.receive_weather_advisory(advisory)
println("queued a weather advisory at stream sequence ", receipt.stream_sequence)
SoleilClient.authorization!(token.access_token)
weather = SoleilClient.get_weather_status(account.id)
deadline = time() + 10
while isempty(weather.advisories) && time() < deadline
    sleep(0.1)
    global weather = SoleilClient.get_weather_status(account.id)
end
tag = only(weather.advisories)
println("weather tag: ", tag.severity, " ", tag.kind, ": ", tag.headline)

SoleilClient.delete_summary(account.id)
println("deleted the stored summary")

# An AI agent uses the MCP tool through one JSON-RPC request to /mcp.
call = (; jsonrpc="2.0", id=1, method="tools/call",
    params=(; name="simulate_solar_exposure", arguments=(; latitude=40.76, longitude=-111.89)))
answer = JSON.parse(HTTP.post("$server_url/mcp", ["Content-Type" => "application/json"], JSON.json(call)).body)
println("MCP tool: ", only(answer.result.content).text)
