# soleil

The Julia environment for the Soleil project. [`Solar`](Solar/) and
[`Soleil`](Soleil/) are local packages that share this directory's
`Manifest.toml`.

Start Julia in this environment:

```sh
julia +1.14.0-alpha2 --project=soleil
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
julia +1.14.0-alpha2 --project=soleil soleil/server_demo.jl
```

The server reads [`config.toml`](config.toml), which sets `port = 9001`. A
`PORT` environment variable or a `--port=...` argument overrides it.

In a second terminal, generate a typed client from the running service and call
it:

```sh
julia +1.14.0-alpha2 --project=soleil soleil/client_demo.jl
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
the JWT signing key) in an
[AbstractStores](https://github.com/JuliaServices/AbstractStores.jl) file
store: one JSON file per key under the `[state]` table's `path`, which is
`soleil/state/` by default. Each kind of record is a typed view of that store
under its own key prefix, and emails are hashed before they become keys.

Earlier checkpoints let configuration choose memory, Redis, SQLite, or Postgres
instead. A compiled binary contains only the code it can reach, so this
checkpoint keeps just the backend it deploys.

The file store writes each value atomically, but it coordinates
read-modify-write updates only within one process, so run one Soleil process
per state directory.

[JuliaServices/NATS.jl](https://github.com/JuliaServices/NATS.jl), used below,
is not in the General registry, so `Project.toml` pins a commit of it.

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
julia +1.14.0-alpha2 --project=soleil soleil/server_demo.jl
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

## Precompilation

[`precompile.jl`](Soleil/src/precompile.jl) is a
[PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl) workload:
while Soleil precompiles, it starts a server and sends one request to every
endpoint. Soleil's OpenAPI document is built while it precompiles, too, so
`/openapi.json` serves a constant string.

## Trimmed binary

This checkpoint compiles Soleil into a native executable with
[JuliaC](https://github.com/JuliaLang/JuliaC.jl) and `--trim=safe`, which keeps
only the code reachable from [`trim/main.jl`](../trim/main.jl), the same
`Soleil.run()` a Julia process runs, and fails the build if any call could not
be resolved ahead of time. It needs Julia 1.14, a prerelease for now, so this
checkpoint's environment is resolved with Julia 1.14.0-alpha2, and every
command in this README uses it:

```sh
juliaup add 1.14.0-alpha2
julia +1.14.0-alpha2 -e 'using Pkg; Pkg.Apps.add(name="JuliaC", version="0.3.12")'
cd trim
juliac --output-exe soleil --bundle ../build --project ../soleil --trim=safe --experimental main.jl
../build/bin/soleil
```

JuliaC links the executable in the current directory before it moves it into
the bundle, so the build runs in `trim/`; at the repository root, the `soleil/`
directory is in the way.

The binary reads `config.toml` from `soleil/`, where it was compiled. Trimmed
binaries do not log, so it prints nothing while it serves. The executable is
about 21 MB, and the bundle, with the Julia runtime libraries, about 63 MB.
Once its signing key is stored, it is ready in under a tenth of a second, and
its first request is as fast as the next.

Ctrl-C does not stop it cleanly yet. JuliaC leaves Julia's Ctrl-C listener out
of trimmed binaries, so SIGINT takes the runtime's fatal-signal path, and on
Julia 1.14.0-alpha2 that path's crash report segfaults; SIGTERM can do the
same. The process still exits, and its state is safe: the file store replaces
each file atomically, and JetStream redelivers any event that was not
acknowledged.

[`docker_server_demo.sh`](../docker_server_demo.sh) builds the Linux binary in
Docker and ships it in a from-scratch image that holds only the executable, its
bundled Julia runtime, and the system libraries they load: about 120 MB, or
50 MB compressed, where the `julia:1.13` image that checkpoint 5 starts from is
about 1.3 GB. It runs the image in
the background with NATS JetStream on a private network, with `PROFILE=docker`
reading [`config-docker.toml`](config-docker.toml), and Enter stops it:

```sh
./docker_server_demo.sh
```

With the container running, run the client from a second terminal:

```sh
julia +1.14.0-alpha2 --project=soleil soleil/client_demo.jl
```

The first `simulate` request is as fast as the second: there is no compiler in
the image, and nothing left to compile.

## Model Context Protocol

Soleil also serves one [Model Context Protocol](https://modelcontextprotocol.io)
tool at `POST /mcp`, so an AI agent can run simulations itself.
`simulate_solar_exposure` takes the same inputs as the public simulation
endpoint, and only latitude and longitude are required. It answers with a short
text summary for the model to read, plus the location, settings, and annual and
monthly totals as structured JSON. Invalid inputs come back as a tool error
that says what to fix.

`client_demo.jl` ends with the request an agent sends to call the tool. To add
the running server to Claude Code:

```sh
claude mcp add --transport http soleil http://127.0.0.1:9001/mcp
```

The tool is public, like the simulation endpoint. The endpoint is stateless: it
keeps no sessions, so any Soleil process can answer any client. It uses
ModelContextProtocol's static server, whose request handling has concrete
types, so the trimmed binary serves it too.
[JuliaServices/ModelContextProtocol.jl](https://github.com/JuliaServices/ModelContextProtocol.jl)
is not in the General registry, so `Project.toml` pins a commit of it.

## Tests

From the repository root:

```sh
julia +1.14.0-alpha2 --project=soleil -e 'using Pkg; Pkg.test(["Solar", "Soleil"])'
```
