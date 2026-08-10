# JuliaCon 2026

Materials for a three-hour JuliaCon 2026 session: building, securing, and
deploying a Julia web service from scratch.

The session builds one application — Soleil, a solar-exposure API over the
[`Solar`](soleil/Solar/) package — in seven phases. Each checkpoint is a branch,
and each branch builds on the tip of the one before it. The deployment phase
uses three checkpoints so each compilation strategy remains runnable:

| Branch | Phase | Introduces |
| --- | --- | --- |
| `checkpoint-0-library` (= `main`) | The library | `Solar`: a plain Julia package |
| `checkpoint-1-service` | The service | Servo endpoints, OpenAPI self-description, a generated typed client |
| `checkpoint-2-auth` | Authentication | Accounts, OAuth-issued JWT bearer tokens, private endpoints |
| `checkpoint-3-state` | State | One AbstractStores backend: memory, file, Redis, SQLite, or Postgres |
| `checkpoint-4-events` | Events | Weather-advisory webhooks through NATS JetStream, Tempus cleanup jobs |
| `checkpoint-5-build-and-deploy` | Deployment: baseline | A plain Julia server in a container |
| `checkpoint-5-build-and-deploy-1` | Deployment: precompile | A PrecompileTools endpoint workload |
| `checkpoint-5-build-and-deploy-2` | Deployment: trim compile | A `juliac --trim=safe` native executable in a from-scratch container |
| `checkpoint-6-mcp` | Model Context Protocol | An MCP tool for AI agents, served by the trimmed binary too |

Checkpoints 0 through 5-1 are resolved and tested with Julia 1.13. Trim
compilation needs Julia 1.14, so checkpoints 5-2 and 6 use Julia 1.14.0-alpha2.

The [`soleil/`](soleil/) application environment contains the packages and
demo scripts for the currently checked-out phase; its README grows with each
phase. Start at `main`, and check out the next `checkpoint-*` branch whenever
you are ready for the next phase.
