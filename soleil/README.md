# soleil

The Julia environment for the Soleil project. [`Solar`](Solar/) is a local
package that shares this directory's `Manifest.toml`.

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

## Tests

From the repository root:

```sh
julia --project=soleil -e 'using Pkg; Pkg.test("Solar")'
```
