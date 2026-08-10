# Usage: julia --project=soleil soleil/server_demo.jl [memory|file|redis|sqlite|postgres]
#
# Memory is the default, so a plain run starts empty. Redis and Postgres run in
# temporary Docker containers.

using Harbor
using Servo
using Soleil

function serve(state)
    server = Soleil.run!(; host="127.0.0.1", configs=Dict{String,Any}("state" => state))
    println("Soleil is serving at http://127.0.0.1:", Servo.port(server), " with ", state["backend"], " state.")
    println("Press Enter to stop it.")
    try
        readline()
    finally
        close(server)
    end
end

backend = isempty(ARGS) ? "memory" : only(ARGS)

if backend in ("memory", "file", "sqlite")
    # config.toml puts the file and SQLite state next to this script.
    serve(Dict{String,Any}("backend" => backend))
elseif backend == "redis"
    Harbor.with_container(
        "redis";
        tag="7",
        ports=Dict(6379 => 0),
        wait_strategy=(pattern="Ready to accept connections",),
        wait_timeout=120.0,
    ) do container
        redis = Dict{String,Any}("port" => Harbor.host_port(container, 6379))
        serve(Dict{String,Any}("backend" => "redis", "redis" => redis))
    end
elseif backend == "postgres"
    # These credentials only exist in this throwaway container.
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
        serve(Dict{String,Any}("backend" => "postgres", "postgres" => postgres))
    end
else
    error("unknown backend $(repr(backend)); expected memory, file, redis, sqlite, or postgres")
end
