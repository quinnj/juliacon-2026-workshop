# Usage: julia --project=soleil soleil/server_demo.jl [memory|file|redis|sqlite|postgres]
#
# NATS JetStream, and Redis or Postgres when chosen, run in temporary Docker
# containers. Memory is the default backend, so a plain run starts empty.

using Harbor
using Servo
using Soleil

# A webhook secret for this demo only; client_demo.jl sends the same value.
const WEBHOOK_SECRET = "soleil-demo-weather-secret"

function serve(state, nats_url)
    events = Dict{String,Any}(
        "enabled" => true,
        "webhook_secret" => WEBHOOK_SECRET,
        # Look for expired advisories every ten seconds instead of hourly.
        "cleanup_schedule" => "*/10 * * * * *",
        "nats" => Dict{String,Any}("url" => nats_url),
    )
    configs = Dict{String,Any}("state" => state, "events" => events)
    server = Soleil.run!(; host="127.0.0.1", configs)
    println("Soleil is serving at http://127.0.0.1:", Servo.port(server), " with ", state["backend"], " state.")
    println("Press Enter to stop it.")
    try
        readline()
    finally
        close(server)
    end
end

# Call `f` with the state settings for `backend`, starting its container if it needs one.
function with_backend(f, backend)
    if backend in ("memory", "file", "sqlite")
        # config.toml puts the file and SQLite state next to this script.
        return f(Dict{String,Any}("backend" => backend))
    elseif backend == "redis"
        return Harbor.with_container(
            "redis";
            tag="7",
            ports=Dict(6379 => 0),
            wait_strategy=(pattern="Ready to accept connections",),
            wait_timeout=120.0,
        ) do container
            f(Dict{String,Any}("backend" => "redis", "redis" => Dict{String,Any}("port" => Harbor.host_port(container, 6379))))
        end
    elseif backend == "postgres"
        # These credentials only exist in this throwaway container.
        return Harbor.with_container(
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
            f(Dict{String,Any}("backend" => "postgres", "postgres" => postgres))
        end
    end
    error("unknown backend $(repr(backend)); expected memory, file, redis, sqlite, or postgres")
end

backend = isempty(ARGS) ? "memory" : only(ARGS)
Harbor.with_container(
    "nats";
    tag="2.10.18",
    ports=Dict(4222 => 0),
    command=["--jetstream"],
    wait_strategy=(pattern="Server is ready",),
    wait_timeout=120.0,
) do nats
    nats_url = "nats://127.0.0.1:$(Harbor.host_port(nats, 4222))"
    with_backend(state -> serve(state, nats_url), backend)
end
