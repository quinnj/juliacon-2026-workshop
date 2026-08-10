# Solar.jl

Solar.jl estimates the sun's position and the clear-sky exposure of a fixed
solar panel at a given location. A yearly simulation keeps every daily result
and summarizes them by month and by year.

## Usage

Solar is a local package in this repository's [`soleil`](..) environment:

```julia
using Dates
using Solar

position = Solar.solar_position(DateTime(2026, 6, 21, 12), 40.39, -111.85)

simulation = Solar.simulate(
    40.39,
    -111.85;
    year=2026,
    panel_tilt_deg=35,
    system_capacity_kw=6,
)

simulation.summary
simulation.daily[1]
```

Azimuth is measured clockwise from north and zenith down from straight
overhead. Irradiation is reported in kWh/m² and estimated energy in kWh.

## Model scope

Solar models approximate Earth–sun geometry, clear-sky direct and diffuse
light, ground reflection, fixed panel orientation, and one aggregate
performance ratio for system losses.

It does not model time zones, weather, shading, snow, soiling, panel
temperature, degradation, tracking, bifacial gain, inverter clipping, or
costs. Use it to compare scenarios, not to size a real system.

## Testing

```sh
julia --project=soleil -e 'using Pkg; Pkg.test("Solar")'
```
