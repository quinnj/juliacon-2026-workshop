#!/usr/bin/env sh
# Usage: ./docker_server_demo.sh
#
# Builds the trimmed image and runs it on a private network with NATS
# JetStream. A named volume keeps Soleil's state between runs.
set -eu

image=soleil:trim
network=soleil-demo-$$
nats=soleil-nats-$$
soleil=soleil-$$

cleanup() {
    docker rm --force "$soleil" "$nats" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker build --tag "$image" .
docker network create "$network" >/dev/null
docker run --detach --name "$nats" --network "$network" --network-alias nats \
    --health-cmd 'wget -qO- http://127.0.0.1:8222/healthz' --health-interval 1s \
    nats:2.10.18-alpine --jetstream -m 8222 >/dev/null
for _ in $(seq 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$nats")" = healthy ] && break
    sleep 1
done

# The trimmed binary cannot shut down on Ctrl-C yet (see soleil/README.md), so
# it runs in the background, and Enter removes its container.
docker run --detach --name "$soleil" --network "$network" --publish 9001:9001 --env PROFILE=docker \
    --volume soleil-state:/app/state "$image" >/dev/null
echo "Soleil is serving at http://127.0.0.1:9001. Press Enter to stop it."
read -r _
