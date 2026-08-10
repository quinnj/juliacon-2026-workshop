using Dates
using Solar
using StructUtils
using Test

@testset "Solar" begin
    @testset "location validation" begin
        @test Solar.Location(40.39, -111.85).latitude == 40.39
        @test_throws ArgumentError Solar.Location(90.1, 0)
        @test_throws ArgumentError Solar.Location(0, -180.1)
    end

    @testset "solar position" begin
        equinox_noon = Solar.solar_position(DateTime(2026, 3, 20, 12), 0, 0)
        @test equinox_noon.zenith_deg < 3
        @test equinox_noon.elevation_deg > 87

        morning =
            Solar.solar_position(DateTime(2026, 6, 21, 9), 40, -105)
        afternoon =
            Solar.solar_position(DateTime(2026, 6, 21, 15), 40, -105)
        @test 45 < morning.azimuth_deg < 180
        @test 180 < afternoon.azimuth_deg < 315
        noon = Solar.solar_position(DateTime(2026, 6, 21, 12), 40, -105)
        @test noon.zenith_deg < 20
        @test noon.azimuth_deg ≈ 180 atol = 3

        east = Solar.SolarPosition(
            DateTime(2026, 6, 21, 9),
            Solar.Location(40, -105),
            -7,
            45,
            45,
            90,
        )
        east_diagram = split(
            sprint(show, MIME"text/plain"(), east),
            '\n',
        )
        @test east_diagram[1] ==
              "SolarPosition @ 2026-06-21T09:00:00"
        @test occursin(
            "azimuth 90.0 deg (E) | elevation +45.0 deg",
            east_diagram[2],
        )
        # +45° is the sixth sky row (line 9). East is map column 13, which
        # is character 20 after the 7-character row label.
        @test findfirst(==('*'), east_diagram[9]) == 20
        # The June day arc is traced with dots for context.
        @test any(line -> occursin('.', line), east_diagram)

        west_below_horizon = Solar.SolarPosition(
            DateTime(2026, 6, 21, 23),
            Solar.Location(40, -105),
            -7,
            135,
            -45,
            270,
        )
        west_diagram = split(
            sprint(show, MIME"text/plain"(), west_below_horizon),
            '\n',
        )
        @test occursin(
            "azimuth 270.0 deg (W) | elevation -45.0 deg",
            west_diagram[2],
        )
        # A sun below the horizon sits on the horizon line (line 14). West is
        # map column 37, character 44.
        @test findfirst(==('*'), west_diagram[14]) == 44
        @test endswith(west_diagram[14], "(* sun below horizon)")

        south_horizon = Solar.SolarPosition(
            DateTime(2026, 12, 21, 17),
            Solar.Location(40, -105),
            -7,
            90,
            0,
            180,
        )
        horizon_diagram = split(
            sprint(show, MIME"text/plain"(), south_horizon),
            '\n',
        )
        @test findfirst(==('*'), horizon_diagram[14]) == 32
        @test endswith(horizon_diagram[14], " horizon")
    end

    @testset "year simulation and summary" begin
        simulation = Solar.simulate(40.39, -111.85; year=2026)
        @test length(simulation.daily) == 365
        @test simulation.daily[1].date == Date(2026, 1, 1)
        @test simulation.daily[end].date == Date(2026, 12, 31)
        @test length(simulation.summary.monthly) == 12

        annual_energy =
            sum(day -> day.estimated_energy_kwh, simulation.daily)
        monthly_energy =
            sum(month -> month.estimated_energy_kwh, simulation.summary.monthly)
        @test simulation.summary.estimated_annual_energy_kwh ≈ annual_energy
        @test monthly_energy ≈ annual_energy
        @test simulation.summary.annual_panel_irradiation_kwh_m2 > 1_000

        june = simulation.summary.monthly[6]
        december = simulation.summary.monthly[12]
        @test june.estimated_energy_kwh > december.estimated_energy_kwh
        @test simulation.daily[172].daylight_hours >
              simulation.daily[355].daylight_hours

        rendered = sprint(show, MIME"text/plain"(), simulation)
        @test occursin("Solar simulation — 2026", rendered)
        @test occursin("Estimated annual production", rendered)
        @test occursin("Daily calculations: 365", rendered)
    end

    @testset "panel orientation and leap years" begin
        south = Solar.simulate(
            40.39,
            -111.85;
            year=2026,
            panel_azimuth_deg=180,
            time_step_minutes=60,
        )
        north = Solar.simulate(
            40.39,
            -111.85;
            year=2026,
            panel_azimuth_deg=0,
            time_step_minutes=60,
        )
        @test south.summary.estimated_annual_energy_kwh >
              north.summary.estimated_annual_energy_kwh

        leap_year = Solar.simulate(0, 0; year=2024, time_step_minutes=60)
        @test length(leap_year.daily) == 366
        @test leap_year.summary.monthly[2].days == 29
    end

    @testset "configuration validation" begin
        @test_throws ArgumentError Solar.simulate(0, 0; year=0)
        @test_throws ArgumentError Solar.simulate(0, 0; system_capacity_kw=0)
        @test_throws ArgumentError Solar.simulate(0, 0; performance_ratio=1.1)
        @test_throws ArgumentError Solar.simulate(
            0,
            0;
            time_step_minutes=17,
        )
    end

    @testset "field metadata" begin
        style = StructUtils.DefaultStyle()

        latitude_tags = StructUtils.fieldtags(
            style,
            Solar.Location,
            :latitude,
        )
        @test latitude_tags.json.name == "latitude_deg"

        step_tags = StructUtils.fieldtags(
            style,
            Solar.SimulationConfig,
            :time_step_minutes,
        )
        @test step_tags.json.ignore

        average_tags = StructUtils.fieldtags(
            style,
            Solar.SolarSummary,
            :average_daily_energy_kwh,
        )
        @test average_tags.json.lower(12.346) == 12.35
    end
end
