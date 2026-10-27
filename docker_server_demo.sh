#!/usr/bin/env sh
# Usage: ./docker_server_demo.sh [memory|file|redis|sqlite|postgres]
#
# Builds the image and runs it on a private network with NATS JetStream and,
# for redis or postgres, a database container. Named volumes keep the file,
# sqlite, redis, and postgres state between runs.
set -eu

backend=${1:-memory}
case "$backend" in
    memory|file|redis|sqlite|postgres) ;;
    *) echo "usage: $0 [memory|file|redis|sqlite|postgres]" >&2; exit 1 ;;
esac

image=soleil:precompiled
network=soleil-demo-$$
containers=

cleanup() {
    [ -z "$containers" ] || docker rm --force $containers >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Run a container on the demo network and wait up to a minute for its health check.
start() {
    name=$1
    shift
    docker run --detach --name "$name" --network "$network" "$@" >/dev/null
    containers="$containers $name"
    for _ in $(seq 60); do
        [ "$(docker inspect --format '{{.State.Health.Status}}' "$name")" = healthy ] && return 0
        sleep 1
    done
    docker logs "$name" >&2
    echo "$name did not become healthy" >&2
    exit 1
}

docker build --tag "$image" .
docker network create "$network" >/dev/null

start "soleil-nats-$$" --network-alias nats \
    --health-cmd 'wget -qO- http://127.0.0.1:8222/healthz' --health-interval 1s \
    nats:2.10.18-alpine --jetstream -m 8222

case "$backend" in
    memory) set -- --tmpfs /app/state ;;
    file | sqlite) set -- --volume "soleil-$backend-state:/app/state" ;;
    redis)
        start "soleil-redis-$$" --network-alias redis \
            --volume soleil-redis-state:/data \
            --health-cmd 'redis-cli ping' --health-interval 1s \
            redis:7
        set --
        ;;
    postgres)
        start "soleil-postgres-$$" --network-alias postgres \
            --volume soleil-postgres-state:/var/lib/postgresql/data \
            --env POSTGRES_PASSWORD=postgres --env POSTGRES_DB=soleil \
            --health-cmd 'pg_isready --username postgres --dbname soleil' --health-interval 1s \
            postgres:16
        set --
        ;;
esac

# On Julia 1.13, Ctrl-C can interrupt one of the server's background tasks
# instead of the server, so the server runs in the background, its log streams
# here, and Enter stops it.
docker run --detach --name "soleil-$$" --network "$network" --publish 9001:9001 \
    --env "PROFILE=docker-$backend" "$@" "$image" >/dev/null
containers="$containers soleil-$$"
echo "Soleil is starting at http://127.0.0.1:9001. Press Enter to stop it."
docker logs --follow "soleil-$$" &
read -r _
