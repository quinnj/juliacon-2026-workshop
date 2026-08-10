# soleil

The Julia environment for the Soleil project. [`Solar`](Solar/) and
[`Soleil`](Soleil/) are local packages that share this directory's
`Manifest.toml`.

Start Julia in this environment:

```sh
julia --project=soleil
```

Then run a one-year solar simulation:

```julia
using Solar

simulation = Solar.simulate(40.39, -111.85; year=2026)
```

`simulation.daily` holds every simulated day and `simulation.summary` the
totals. The [Solar README](Solar/README.md) covers the API and the model.

## The service

`Soleil` serves Solar as a JSON API with
[Servo](https://github.com/JuliaServices/Servo.jl): a public
`GET /v1/simulate/{latitude}/{longitude}` endpoint, plus an OpenAPI description
of the API at `/openapi.json`. Start it from the repository root:

```sh
julia --project=soleil soleil/server_demo.jl
```

The server reads [`config.toml`](config.toml), which sets `port = 9001`. A
`PORT` environment variable or a `--port=...` argument overrides it.

In a second terminal, generate a typed client from the running service and call
it:

```sh
julia --project=soleil soleil/client_demo.jl
```

[client_demo.jl](client_demo.jl) reads `/openapi.json` and writes
`SoleilClient.jl`: a function per endpoint and a struct per schema. It then
calls `SoleilClient.simulate(40.76, -111.89; system_capacity_kw=8.0)`, which
returns a typed `SolarSummary`, and shows a validation error coming back as a
typed `SoleilClient.ApiError`. `SoleilClient.jl` is regenerated on every run.

## Accounts and authentication

Each user has an account, issued tokens, and one stored solar summary. Account
ids are 128-bit random [Encid](https://github.com/JuliaServices/Encid.jl) ids,
written in Base58.

| Method | Path | Access | Purpose |
| --- | --- | --- | --- |
| `POST` | `/v1/accounts` | Public | Create an account from an email and password |
| `POST` | `/v1/login` | Public | Check the credentials and return a bearer token |
| `POST` | `/v1/simulate/{userId}` | Bearer | Create the user's stored summary |
| `GET` | `/v1/simulate/{userId}` | Bearer | Read the user's stored summary |
| `PUT` | `/v1/simulate/{userId}` | Bearer | Replace the user's stored summary |
| `DELETE` | `/v1/simulate/{userId}` | Bearer | Delete the user's stored summary |

[OAuth.jl](https://github.com/JuliaServices/OAuth.jl) issues RS256-signed JWT
access tokens and records each one. On a private request, `Servo.BearerAuth`
reads the `Authorization` header and calls Soleil's token validator.
[JWTs.jl](https://github.com/JuliaWeb/JWTs.jl) checks the signature, issuer,
audience, expiry, and required claims, then OAuth.jl confirms that it issued
the token and has not revoked it. The validator's result becomes
`Servo.principal()`, and each handler checks that the token's user owns the
`{userId}` in the path.

`/v1/login` is an application endpoint, not an OAuth password grant: Soleil
checks the password itself, then asks OAuth.jl's token service for a token.

Passwords are stored as a salted SHA-256 digest. That keeps them out of plain
text, but SHA-256 is not a password hash; a production service needs Argon2id,
scrypt, or bcrypt.

[client_demo.jl](client_demo.jl) now also creates an account, logs in, and
creates, reads, updates, and deletes that account's stored summary.

## State

Soleil keeps all of its state (accounts, stored summaries, issued tokens, and
the JWT signing key) in one
[AbstractStores](https://github.com/JuliaServices/AbstractStores.jl) backend.
Each kind of record is a typed view of that backend under its own key prefix,
so one backend is one thing to back up. Emails are hashed before they become
keys. The `[state]` table in [`config.toml`](config.toml) chooses the backend:

| `backend` | Settings | Stores state |
| --- | --- | --- |
| `memory` | | In the server process, until it exits |
| `file` (default) | `path` | As one JSON file per key, under `soleil/state/` |
| `redis` | `redis.host`, `redis.port`, `redis.db`, `redis.prefix` | In Redis |
| `sqlite` | `sqlite.path`, `sql.table` | In one table of `soleil/state.sqlite` |
| `postgres` | `postgres.host`, `postgres.port`, `postgres.user`, `postgres.password`, `postgres.database`, `sql.table` | In one Postgres table |

The server demo takes the backend as its argument and uses memory by default:

```sh
julia --project=soleil soleil/server_demo.jl file
```

For `redis` and `postgres` the demo starts a temporary container with
[Harbor](https://github.com/JuliaServices/Harbor.jl), so Docker must be
running.

The file backend writes each value atomically, but it coordinates
read-modify-write updates only within one process. Redis and the SQL backends
make those updates atomic across processes, so use one of them when several
Soleil processes share state. The SQL backends create their table if it does
not exist; later schema changes are up to you. Keep real database passwords out
of `config.toml`, for example in a git-ignored `.config-<profile>.toml`.

Redis and the SQL backends store values with Julia's `Serialization` stdlib,
whose format can change between Julia versions; never load state from an
untrusted source.

[JuliaServices/Redis.jl](https://github.com/JuliaServices/Redis.jl) is not in
the General registry, so `Project.toml` pins a commit of it, and AbstractStores
cannot declare its Redis extension yet. Soleil includes the extension's source
file directly instead. [JuliaServices/NATS.jl](https://github.com/JuliaServices/NATS.jl),
used below, is pinned the same way.

## Weather events

Soleil can take weather advisories from an external provider and tag the stored
summaries they affect:

1. A provider posts an advisory to `/v1/webhooks/weather-advisories`,
   authenticated with its own bearer secret (`events.webhook_secret`), not a
   user token.
2. [NATS JetStream](https://docs.nats.io/nats-concepts/jetstream) stores the
   advisory before the webhook responds, and ignores a retry that repeats the
   advisory's id.
3. A background worker pulls advisories with explicit acknowledgements and tags
   every stored summary inside the advisory's latitude/longitude box. Applying
   an advisory twice changes nothing.
4. A [Tempus](https://github.com/JuliaServices/Tempus.jl) job removes tags once
   their advisory has ended. Tempus keeps the job and its run history in the
   same state backend as everything else, under `tempus/`.

A user reads their tags from `GET /v1/weather/{userId}`.

Events are off in `config.toml`, because they need a NATS server. The server
demo turns them on, starts NATS in a temporary container, and looks for expired
advisories every ten seconds instead of hourly:

```sh
julia --project=soleil soleil/server_demo.jl [backend]
```

[client_demo.jl](client_demo.jl) then posts an advisory over Utah and waits for
its tag on the demo user's summary. A webhook request looks like this:

```sh
curl -X POST http://127.0.0.1:9001/v1/webhooks/weather-advisories \
  -H 'Authorization: Bearer soleil-demo-weather-secret' \
  -H 'Content-Type: application/json' \
  -d '{"id": "utah-hail-001", "kind": "hail", "severity": "severe",
       "headline": "Large hail may damage exposed panels",
       "bounds": {"south": 37.0, "west": -114.1, "north": 42.1, "east": -109.0},
       "starts_at": "2099-06-01T18:00:00", "ends_at": "2099-06-01T22:00:00"}'
```

Matching is a plain bounding-box test: an advisory is a rectangle that cannot
cross the date line, the worker scans every stored summary, and an advisory
tags only the summaries that exist when it is processed. Set a real
`events.webhook_secret` through a secret source, never in `config.toml`.

## Container image

[`docker_server_demo.sh`](../docker_server_demo.sh) builds the repository's
[`Dockerfile`](../Dockerfile) as `soleil:jit` and runs it with NATS JetStream
on a private Docker network. It takes the state backend as its argument and
uses memory by default; `redis` and `postgres` also start a database container:

```sh
./docker_server_demo.sh file
```

Each `PROFILE=docker-<backend>` run reads `config-docker-<backend>.toml`, which
enables events and points at the demo's containers. The server's log streams to
the terminal, and Enter stops it. Named volumes keep the file, SQLite, Redis,
and Postgres state, including the JWT signing key, between runs.

With the container running, run the client from a second terminal:

```sh
julia --project=soleil soleil/client_demo.jl
```

The client first times two identical `simulate` requests. The image is plain
Julia, so the first request also compiles the code it runs, and takes much
longer than the second.

## Tests

From the repository root:

```sh
julia --project=soleil -e 'using Pkg; Pkg.test(["Solar", "Soleil"])'
```
