# Usage: julia --project=soleil soleil/server_demo.jl
#
# Runs Soleil with its state in soleil/state/ and NATS JetStream in a temporary
# Docker container.

using Harbor
using Servo
using Soleil

# A webhook secret for this demo only; client_demo.jl sends the same value.
const WEBHOOK_SECRET = "soleil-demo-weather-secret"

Harbor.with_container(
    "nats";
    tag="2.10.18",
    ports=Dict(4222 => 0),
    command=["--jetstream"],
    wait_strategy=(pattern="Server is ready",),
    wait_timeout=120.0,
) do nats
    events = Dict{String,Any}(
        "enabled" => true,
        "webhook_secret" => WEBHOOK_SECRET,
        # Look for expired advisories every ten seconds instead of hourly.
        "cleanup_schedule" => "*/10 * * * * *",
        "nats" => Dict{String,Any}("url" => "nats://127.0.0.1:$(Harbor.host_port(nats, 4222))"),
    )
    server = Soleil.run!(; host="127.0.0.1", configs=Dict{String,Any}("events" => events))
    println("Soleil is serving at http://127.0.0.1:", Servo.port(server), ". Press Enter to stop it.")
    try
        readline()
    finally
        close(server)
    end
end
