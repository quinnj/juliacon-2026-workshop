module Solar

using Dates
using Printf
using StructUtils

const SOLAR_CONSTANT_KW_M2 = 1.367

# The model is a pipeline with one function per stage:
#
#   _solar_orbit → _solar_angles → _irradiance → _simulate_day → _summarize

"""
    Location(latitude, longitude)

A geographic point in decimal degrees: latitude in `[-90, 90]`, longitude in
`[-180, 180]`.
"""
StructUtils.@tags struct Location
    # The JSON names carry the unit; the Julia names stay short.
    latitude::Float64 &(json=(name="latitude_deg",),)
    longitude::Float64 &(json=(name="longitude_deg",),)

    function Location(latitude::Real, longitude::Real)
        -90 <= latitude <= 90 ||
            throw(ArgumentError("latitude must be between -90 and 90 degrees"))
        -180 <= longitude <= 180 ||
            throw(ArgumentError("longitude must be between -180 and 180 degrees"))
        return new(Float64(latitude), Float64(longitude))
    end
end

"""
The sun's apparent position at a local date and time.

Azimuth is measured clockwise from north, zenith down from straight overhead,
and elevation up from the horizon (`90 - zenith`). The location and UTC offset
are kept so `show` can draw the whole day's sun path.
"""
struct SolarPosition
    timestamp::DateTime
    location::Location
    utc_offset_hours::Float64
    zenith_deg::Float64
    elevation_deg::Float64
    azimuth_deg::Float64
end

"""Configuration used to produce a [`SolarSimulation`](@ref)."""
StructUtils.@tags struct SimulationConfig
    year::Int
    utc_offset_hours::Float64
    panel_tilt_deg::Float64
    panel_azimuth_deg::Float64
    system_capacity_kw::Float64
    performance_ratio::Float64
    atmospheric_transmittance::Float64
    ground_albedo::Float64
    # An implementation detail: kept in Julia, left out of JSON.
    time_step_minutes::Int &(json=(ignore=true,),)
end

"""One day of solar availability and panel production."""
struct DailySolar
    date::Date
    sunrise::Union{Time,Nothing}
    sunset::Union{Time,Nothing}
    daylight_hours::Float64
    peak_elevation_deg::Float64
    horizontal_irradiation_kwh_m2::Float64
    panel_irradiation_kwh_m2::Float64
    estimated_energy_kwh::Float64
end

"""Totals for one calendar month."""
struct MonthlySolarSummary
    month::Int
    days::Int
    horizontal_irradiation_kwh_m2::Float64
    panel_irradiation_kwh_m2::Float64
    estimated_energy_kwh::Float64
end

"""Annual totals and extremes derived from the days of a [`SolarSimulation`](@ref)."""
StructUtils.@tags struct SolarSummary
    annual_horizontal_irradiation_kwh_m2::Float64
    annual_panel_irradiation_kwh_m2::Float64
    estimated_annual_energy_kwh::Float64
    # Rounded only when written as JSON; the Julia value keeps full precision.
    average_daily_energy_kwh::Float64 &(
        json=(lower=value -> round(value; digits=2),),
    )
    best_day::Date
    best_day_energy_kwh::Float64
    lowest_day::Date
    lowest_day_energy_kwh::Float64
    monthly::Vector{MonthlySolarSummary}
end

"""
    SolarSimulation

One year of daily results plus their [`SolarSummary`](@ref).
"""
struct SolarSimulation
    location::Location
    config::SimulationConfig
    daily::Vector{DailySolar}
    summary::SolarSummary
end

function Base.show(io::IO, location::Location)
    @printf(io, "Location(%.4f°, %.4f°)", location.latitude, location.longitude)
end

function Base.show(io::IO, position::SolarPosition)
    @printf(
        io,
        "SolarPosition(zenith=%.1f°, elevation=%.1f°, azimuth=%.1f°)",
        position.zenith_deg,
        position.elevation_deg,
        position.azimuth_deg,
    )
end

const _SKY_MAP_WIDTH = 49
# Rows above the horizon, 9° of elevation each. The horizon is the chart's
# bottom frame, not a canvas row.
const _SKY_MAP_ROWS = 10
const _ARC_SAMPLE_MINUTES = 10
const _COMPASS_POINTS = ("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")

function _compass_point(azimuth_deg::Real)
    # Each 22.5° sector is centered on its point, so 348.75°–360° folds into N.
    shifted = mod(Float64(azimuth_deg) + 11.25, 360)
    return _COMPASS_POINTS[floor(Int, shifted / 22.5) + 1]
end

_sky_column(azimuth_deg::Real) = round(
    Int,
    1 + (mod(Float64(azimuth_deg), 360) / 360) * (_SKY_MAP_WIDTH - 1),
)

# Elevation 90° maps to row 1; 0° maps to row `_SKY_MAP_ROWS + 1`, the horizon.
_sky_row(elevation_deg::Real) = round(
    Int,
    1 + ((90 - clamp(Float64(elevation_deg), 0, 90)) / 90) * _SKY_MAP_ROWS,
)

function _sky_map(position::SolarPosition)
    canvas = fill(' ', _SKY_MAP_ROWS, _SKY_MAP_WIDTH)

    # Columns run clockwise from north; rows run from the zenith down to the
    # horizon. Dots trace the sun's path over the position's date.
    date = Date(position.timestamp)
    half_step = _ARC_SAMPLE_MINUTES / 2
    for minute in half_step:_ARC_SAMPLE_MINUTES:(1440 - half_step)
        angles = _solar_angles(
            date,
            minute,
            position.location,
            position.utc_offset_hours,
        )
        row = _sky_row(angles.elevation_deg)
        (angles.elevation_deg > 0 && row <= _SKY_MAP_ROWS) || continue
        canvas[row, _sky_column(angles.azimuth_deg)] = '.'
    end

    if position.elevation_deg > 0
        row = _sky_row(position.elevation_deg)
        if row <= _SKY_MAP_ROWS
            canvas[row, _sky_column(position.azimuth_deg)] = '*'
        end
    end
    return canvas
end

"""
Draw an ASCII sky map of a [`SolarPosition`](@ref).

The horizontal axis is azimuth clockwise from north; the vertical axis is
elevation from the horizon up to the zenith. Dots trace the sun's path over the
position's date and `*` marks the position. A sun at or below the horizon is
drawn on the horizon line at its azimuth.
"""
function Base.show(
    io::IO,
    ::MIME"text/plain",
    position::SolarPosition,
)
    canvas = _sky_map(position)
    compass = fill(' ', _SKY_MAP_WIDTH)
    compass[1] = 'N'
    compass[13] = 'E'
    compass[25] = 'S'
    compass[37] = 'W'
    compass[49] = 'N'

    println(io, "SolarPosition @ $(position.timestamp)")
    @printf(
        io,
        "  azimuth %.1f deg (%s) | elevation %+.1f deg | zenith %.1f deg\n",
        mod(position.azimuth_deg, 360),
        _compass_point(position.azimuth_deg),
        position.elevation_deg,
        position.zenith_deg,
    )
    println(io, "      +", repeat("-", _SKY_MAP_WIDTH), "+")
    for row in axes(canvas, 1)
        label = row == 1 ? "+90" : row == 6 ? "+45" : ""
        annotation = row == 1 ? " zenith" : ""
        @printf(io, "%5s |%s|%s\n", label, String(canvas[row, :]), annotation)
    end

    horizon = fill('-', _SKY_MAP_WIDTH)
    if position.elevation_deg <= 0 ||
       _sky_row(position.elevation_deg) > _SKY_MAP_ROWS
        horizon[_sky_column(position.azimuth_deg)] = '*'
    end
    note = position.elevation_deg < 0 ? "  (* sun below horizon)" : ""
    @printf(io, "%5s +%s+ horizon%s\n", "0", String(horizon), note)
    print(io, "       ", String(compass))
end

function Base.show(io::IO, summary::SolarSummary)
    @printf(
        io,
        "SolarSummary(annual panel exposure=%.0f kWh/m², estimated energy=%.0f kWh)",
        summary.annual_panel_irradiation_kwh_m2,
        summary.estimated_annual_energy_kwh,
    )
end

function Base.show(io::IO, ::MIME"text/plain", simulation::SolarSimulation)
    summary = simulation.summary
    monthly = summary.monthly
    best_month = argmax(month -> month.estimated_energy_kwh, monthly)
    lowest_month = argmin(month -> month.estimated_energy_kwh, monthly)

    println(io, "Solar simulation — $(simulation.config.year)")
    @printf(
        io,
        "  Location: %.4f°, %.4f°\n",
        simulation.location.latitude,
        simulation.location.longitude,
    )
    @printf(
        io,
        "  Array: %.1f kW, %.0f° tilt, %.0f° azimuth\n",
        simulation.config.system_capacity_kw,
        simulation.config.panel_tilt_deg,
        simulation.config.panel_azimuth_deg,
    )
    @printf(
        io,
        "  Annual panel exposure: %.0f kWh/m²\n",
        summary.annual_panel_irradiation_kwh_m2,
    )
    @printf(
        io,
        "  Estimated annual production: %.0f kWh (%.1f kWh/day)\n",
        summary.estimated_annual_energy_kwh,
        summary.average_daily_energy_kwh,
    )
    @printf(
        io,
        "  Strongest month: %s (%.0f kWh); weakest: %s (%.0f kWh)\n",
        monthname(best_month.month),
        best_month.estimated_energy_kwh,
        monthname(lowest_month.month),
        lowest_month.estimated_energy_kwh,
    )
    print(io, "  Daily calculations: $(length(simulation.daily))")
end

function _validate_offset(utc_offset_hours::Real)
    -14 <= utc_offset_hours <= 14 ||
        throw(ArgumentError("utc_offset_hours must be between -14 and 14"))
    return Float64(utc_offset_hours)
end

"""
The fractional-year angle γ (radians) of a date and local clock hour, as used
by NOAA's Fourier approximations below.
"""
function _fractional_year(date::Date, local_hour::Real)
    days = daysinyear(date)
    return (2 * π / days) *
           (dayofyear(date) - 1 + (Float64(local_hour) - 12) / 24)
end

"""
NOAA's Fourier approximations of three orbital terms:

  * the equation of time, which shifts solar time against clock time;
  * the solar declination, which sets the sun's seasonal height;
  * the Earth–sun distance factor, which scales extraterrestrial irradiance.

Good enough for scenario modeling; not a precise ephemeris.
"""
function _solar_orbit(date::Date, local_hour::Real)
    γ = _fractional_year(date, local_hour)
    equation_of_time_minutes = 229.18 * (
        0.000075 +
        0.001868 * cos(γ) -
        0.032077 * sin(γ) -
        0.014615 * cos(2 * γ) -
        0.040849 * sin(2 * γ)
    )
    declination_rad =
        0.006918 -
        0.399912 * cos(γ) +
        0.070257 * sin(γ) -
        0.006758 * cos(2 * γ) +
        0.000907 * sin(2 * γ) -
        0.002697 * cos(3 * γ) +
        0.00148 * sin(3 * γ)
    distance_factor =
        1.00011 +
        0.034221 * cos(γ) +
        0.00128 * sin(γ) +
        0.000719 * cos(2 * γ) +
        0.000077 * sin(2 * γ)
    return (; equation_of_time_minutes, declination_rad, distance_factor)
end

"""
Sun angles at one location and local clock minute.

The UTC offset is a fixed number of hours (no time zones or daylight saving),
and atmospheric refraction, observer elevation, and terrain are ignored.
"""
function _solar_angles(
    date::Date,
    minute_of_day::Real,
    location::Location,
    utc_offset_hours::Real,
)
    local_hour = Float64(minute_of_day) / 60
    orbit = _solar_orbit(date, local_hour)

    # Apparent solar time: the clock minute shifted by the equation of time and
    # by 4 minutes per degree of longitude away from the UTC offset's meridian.
    solar_minutes = mod(
        Float64(minute_of_day) +
        orbit.equation_of_time_minutes +
        4 * location.longitude -
        60 * utc_offset_hours,
        1440,
    )

    # The Earth turns 1° every 4 minutes; the hour angle is 0 at solar noon.
    hour_angle_deg = solar_minutes / 4 - 180
    latitude_rad = deg2rad(location.latitude)
    hour_angle_rad = deg2rad(hour_angle_deg)

    cos_zenith = clamp(
        sin(latitude_rad) * sin(orbit.declination_rad) +
        cos(latitude_rad) * cos(orbit.declination_rad) * cos(hour_angle_rad),
        -1,
        1,
    )
    zenith_rad = acos(cos_zenith)

    # atan keeps the quadrant; +180° turns it into degrees clockwise from north.
    azimuth_deg = mod(
        rad2deg(
            atan(
                sin(hour_angle_rad),
                cos(hour_angle_rad) * sin(latitude_rad) -
                tan(orbit.declination_rad) * cos(latitude_rad),
            ),
        ) + 180,
        360,
    )

    return (;
        zenith_deg=rad2deg(zenith_rad),
        elevation_deg=90 - rad2deg(zenith_rad),
        azimuth_deg,
        cos_zenith,
        orbit.distance_factor,
    )
end

"""
    solar_position(timestamp, latitude, longitude;
                   utc_offset_hours=longitude / 15)

Approximate the sun's position at `timestamp`, read as local clock time. The
default offset is local solar time. Uses NOAA's compact approximation, so it
suits scenario modeling, not surveying: there are no named time zones or
daylight saving, and no refraction, elevation, or terrain corrections.
"""
function solar_position(
    timestamp::DateTime,
    latitude::Real,
    longitude::Real;
    utc_offset_hours::Real=longitude / 15,
)
    location = Location(latitude, longitude)
    offset = _validate_offset(utc_offset_hours)
    minute_of_day =
        60 * Dates.hour(timestamp) +
        Dates.minute(timestamp) +
        Dates.second(timestamp) / 60 +
        Dates.millisecond(timestamp) / 60_000
    angles = _solar_angles(Date(timestamp), minute_of_day, location, offset)
    return SolarPosition(
        timestamp,
        location,
        offset,
        angles.zenith_deg,
        angles.elevation_deg,
        angles.azimuth_deg,
    )
end

"""
Sunrise, sunset, and daylight hours for one date.

Uses a level horizon and the sun's center crossing 0° elevation, and handles
polar day and night. Published tables also account for refraction and the
sun's radius, so they differ by a few minutes.
"""
function _daylight(
    date::Date,
    location::Location,
    utc_offset_hours::Float64,
)
    orbit = _solar_orbit(date, 12)
    latitude_rad = deg2rad(location.latitude)
    hour_angle_cos = -tan(latitude_rad) * tan(orbit.declination_rad)

    if hour_angle_cos >= 1
        return (nothing, nothing, 0.0)
    elseif hour_angle_cos <= -1
        return (nothing, nothing, 24.0)
    end

    hour_angle_deg = rad2deg(acos(hour_angle_cos))
    solar_noon_minutes =
        720 -
        4 * location.longitude -
        orbit.equation_of_time_minutes +
        60 * utc_offset_hours
    sunrise_minutes = solar_noon_minutes - 4 * hour_angle_deg
    sunset_minutes = solar_noon_minutes + 4 * hour_angle_deg
    return (
        _minute_as_time(sunrise_minutes),
        _minute_as_time(sunset_minutes),
        2 * hour_angle_deg / 15,
    )
end

"""Convert clock minutes, possibly outside `[0, 1440)`, to a wrapped `Time`."""
function _minute_as_time(minute::Real)
    milliseconds = mod(round(Int, Float64(minute) * 60_000), 86_400_000)
    return Time(Nanosecond(milliseconds * 1_000_000))
end

"""
Clear-sky horizontal and fixed-panel irradiance at one instant, in kW/m².

Combines the direct beam (attenuated by air mass and one transmittance
parameter), isotropic diffuse sky light, and ground reflection. Clouds,
shading, temperature, and soiling are not modeled.
"""
function _irradiance(
    date::Date,
    minute_of_day::Real,
    location::Location,
    config::SimulationConfig,
)
    angles = _solar_angles(date, minute_of_day, location, config.utc_offset_hours)
    angles.cos_zenith > 0 || return (0.0, 0.0, angles.elevation_deg)

    # Kasten–Young air mass stays finite at the horizon, unlike 1 / cos(z).
    zenith = angles.zenith_deg
    air_mass =
        1 /
        (
            angles.cos_zenith +
            0.50572 * (96.07995 - min(zenith, 90))^(-1.6364)
        )

    extraterrestrial_normal = SOLAR_CONSTANT_KW_M2 * angles.distance_factor
    direct_normal =
        extraterrestrial_normal *
        config.atmospheric_transmittance^(air_mass^0.678)
    diffuse_horizontal = 0.12 * extraterrestrial_normal * angles.cos_zenith
    global_horizontal = direct_normal * angles.cos_zenith + diffuse_horizontal

    # Project the beam onto the panel; sky and ground light use view factors
    # that depend only on tilt.
    tilt_rad = deg2rad(config.panel_tilt_deg)
    azimuth_difference = deg2rad(angles.azimuth_deg - config.panel_azimuth_deg)
    cos_incidence =
        angles.cos_zenith * cos(tilt_rad) +
        sin(deg2rad(zenith)) * sin(tilt_rad) * cos(azimuth_difference)
    beam_on_panel = direct_normal * max(cos_incidence, 0)
    sky_diffuse_on_panel = diffuse_horizontal * (1 + cos(tilt_rad)) / 2
    ground_reflected =
        global_horizontal *
        config.ground_albedo *
        (1 - cos(tilt_rad)) / 2
    panel_irradiance = beam_on_panel + sky_diffuse_on_panel + ground_reflected

    return (global_horizontal, panel_irradiance, angles.elevation_deg)
end

"""
Integrate one day of irradiance into a `DailySolar`.

Samples the midpoint of each `time_step_minutes` interval. Energy is panel
irradiation × nameplate capacity × one aggregate performance ratio that stands
in for all system losses.
"""
function _simulate_day(
    date::Date,
    location::Location,
    config::SimulationConfig,
)
    horizontal_irradiation = 0.0
    panel_irradiation = 0.0
    peak_elevation = -90.0
    step_hours = config.time_step_minutes / 60
    first_midpoint = config.time_step_minutes / 2

    for minute in
        first_midpoint:config.time_step_minutes:(1440 - first_midpoint)
        horizontal, panel, elevation =
            _irradiance(date, minute, location, config)
        horizontal_irradiation += horizontal * step_hours
        panel_irradiation += panel * step_hours
        peak_elevation = max(peak_elevation, elevation)
    end

    sunrise, sunset, daylight_hours =
        _daylight(date, location, config.utc_offset_hours)
    estimated_energy =
        panel_irradiation *
        config.system_capacity_kw *
        config.performance_ratio

    return DailySolar(
        date,
        sunrise,
        sunset,
        daylight_hours,
        peak_elevation,
        horizontal_irradiation,
        panel_irradiation,
        estimated_energy,
    )
end

"""Reduce daily results to monthly and annual totals and extremes."""
function _summarize(daily::Vector{DailySolar})
    isempty(daily) && throw(ArgumentError("cannot summarize an empty simulation"))

    energy = sum(day -> day.estimated_energy_kwh, daily)
    best_day = argmax(day -> day.estimated_energy_kwh, daily)
    lowest_day = argmin(day -> day.estimated_energy_kwh, daily)
    monthly = map(1:12) do month
        days = filter(day -> Dates.month(day.date) == month, daily)
        MonthlySolarSummary(
            month,
            length(days),
            sum(day -> day.horizontal_irradiation_kwh_m2, days),
            sum(day -> day.panel_irradiation_kwh_m2, days),
            sum(day -> day.estimated_energy_kwh, days),
        )
    end

    return SolarSummary(
        sum(day -> day.horizontal_irradiation_kwh_m2, daily),
        sum(day -> day.panel_irradiation_kwh_m2, daily),
        energy,
        energy / length(daily),
        best_day.date,
        best_day.estimated_energy_kwh,
        lowest_day.date,
        lowest_day.estimated_energy_kwh,
        monthly,
    )
end

"""
    simulate(latitude, longitude; kwargs...) -> SolarSimulation

Simulate one year of clear-sky solar exposure and fixed-panel production.

Defaults describe a fixed array facing south (in the northern hemisphere):

  * `year=year(today())`
  * `utc_offset_hours=longitude / 15` (local solar time)
  * `panel_tilt_deg=abs(latitude)`
  * `panel_azimuth_deg=180`
  * `system_capacity_kw=6`
  * `performance_ratio=0.80`
  * `atmospheric_transmittance=0.72`
  * `ground_albedo=0.20`
  * `time_step_minutes=15`

The model covers sun geometry, clear-sky direct and diffuse light, ground
reflection, and panel orientation. It ignores weather, time zones, shading,
snow, soiling, temperature, degradation, tracking, and inverter limits, so use
it to compare scenarios, not to size a real system.
"""
function simulate(
    latitude::Real,
    longitude::Real;
    year::Integer=Dates.year(today()),
    utc_offset_hours::Real=longitude / 15,
    panel_tilt_deg::Real=abs(latitude),
    panel_azimuth_deg::Real=180,
    system_capacity_kw::Real=6,
    performance_ratio::Real=0.80,
    atmospheric_transmittance::Real=0.72,
    ground_albedo::Real=0.20,
    time_step_minutes::Integer=15,
)
    location = Location(latitude, longitude)
    offset = _validate_offset(utc_offset_hours)
    1 <= year <= 9999 || throw(ArgumentError("year must be between 1 and 9999"))
    0 <= panel_tilt_deg <= 180 ||
        throw(ArgumentError("panel_tilt_deg must be between 0 and 180"))
    0 <= panel_azimuth_deg <= 360 ||
        throw(ArgumentError("panel_azimuth_deg must be between 0 and 360"))
    system_capacity_kw > 0 ||
        throw(ArgumentError("system_capacity_kw must be positive"))
    0 < performance_ratio <= 1 ||
        throw(ArgumentError("performance_ratio must be in (0, 1]"))
    0 < atmospheric_transmittance < 1 ||
        throw(ArgumentError("atmospheric_transmittance must be in (0, 1)"))
    0 <= ground_albedo <= 1 ||
        throw(ArgumentError("ground_albedo must be between 0 and 1"))
    1 <= time_step_minutes <= 60 ||
        throw(ArgumentError("time_step_minutes must be between 1 and 60"))
    1440 % time_step_minutes == 0 ||
        throw(ArgumentError("time_step_minutes must divide evenly into one day"))

    config = SimulationConfig(
        Int(year),
        offset,
        Float64(panel_tilt_deg),
        Float64(panel_azimuth_deg),
        Float64(system_capacity_kw),
        Float64(performance_ratio),
        Float64(atmospheric_transmittance),
        Float64(ground_albedo),
        Int(time_step_minutes),
    )
    dates = Date(config.year):Day(1):Date(config.year, 12, 31)
    daily = [_simulate_day(date, location, config) for date in dates]
    return SolarSimulation(location, config, daily, _summarize(daily))
end

end
