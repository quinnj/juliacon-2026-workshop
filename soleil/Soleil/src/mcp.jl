const MCP = ModelContextProtocol

"""
The arguments of the `simulate_solar_exposure` tool. Only the location is
required; a missing argument parses as `nothing` and gets `Solar.simulate`'s
default.
"""
struct SimulationArguments
    latitude::Float64
    longitude::Float64
    year::Union{Nothing,Int}
    utc_offset_hours::Union{Nothing,Float64}
    panel_tilt_deg::Union{Nothing,Float64}
    panel_azimuth_deg::Union{Nothing,Float64}
    system_capacity_kw::Union{Nothing,Float64}
    performance_ratio::Union{Nothing,Float64}
    atmospheric_transmittance::Union{Nothing,Float64}
    ground_albedo::Union{Nothing,Float64}
    time_step_minutes::Union{Nothing,Int}
end

const SIMULATION_ARGUMENTS_SCHEMA = JSON.json(Dict(
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["latitude", "longitude"],
    "properties" => Dict(
        name => Dict("type" => type, "description" => description) for (name, type, description) in [
            ("latitude", "number", "Latitude in decimal degrees, from -90 to 90."),
            ("longitude", "number", "Longitude in decimal degrees, from -180 to 180."),
            ("year", "integer", "Calendar year. Defaults to the current year."),
            ("utc_offset_hours", "number", "Fixed UTC offset. Defaults to longitude / 15."),
            ("panel_tilt_deg", "number", "Panel tilt from horizontal. Defaults to the absolute latitude."),
            ("panel_azimuth_deg", "number", "Panel azimuth clockwise from north. Defaults to 180."),
            ("system_capacity_kw", "number", "Rated system capacity in kW. Defaults to 6."),
            ("performance_ratio", "number", "System efficiency from 0 to 1. Defaults to 0.8."),
            ("atmospheric_transmittance", "number", "Clear-sky transmittance from 0 to 1. Defaults to 0.72."),
            ("ground_albedo", "number", "Ground reflectivity from 0 to 1. Defaults to 0.2."),
            ("time_step_minutes", "integer", "Integration step in minutes. Defaults to 15."),
        ]
    ),
))

function _simulate(args::SimulationArguments)
    return Solar.simulate(
        args.latitude,
        args.longitude;
        year=something(args.year, Dates.year(Dates.today())),
        utc_offset_hours=something(args.utc_offset_hours, args.longitude / 15),
        panel_tilt_deg=something(args.panel_tilt_deg, abs(args.latitude)),
        panel_azimuth_deg=something(args.panel_azimuth_deg, 180.0),
        system_capacity_kw=something(args.system_capacity_kw, 6.0),
        performance_ratio=something(args.performance_ratio, 0.8),
        atmospheric_transmittance=something(args.atmospheric_transmittance, 0.72),
        ground_albedo=something(args.ground_albedo, 0.2),
        time_step_minutes=something(args.time_step_minutes, 15),
    )
end

"""The handler of the `simulate_solar_exposure` MCP tool."""
struct SimulateSolarExposure end

function (::SimulateSolarExposure)(::MCP.StaticMCPRequestContext, arguments::JSON.JSONText)
    simulation = try
        _simulate(JSON.parse(arguments.value, SimulationArguments))
    catch error
        # Answer invalid arguments with a tool error, which shows the model what
        # to fix, rather than a protocol error, which does not.
        error isa ArgumentError || rethrow()
        return MCP.StaticMCPToolResult(; text=error.msg isa String ? error.msg : "invalid arguments", is_error=true)
    end
    (; location, config, summary) = simulation
    kwh(energy) = string(round(energy; digits=1), " kWh")
    best = argmax(month -> month.estimated_energy_kwh, summary.monthly)
    monthly = join((string(Dates.monthabbr(m.month), " ", kwh(m.estimated_energy_kwh)) for m in summary.monthly), ", ")
    text = string(
        "A $(config.system_capacity_kw) kW fixed panel array at $(location.latitude), $(location.longitude) ",
        "would produce about $(kwh(summary.estimated_annual_energy_kwh)) in $(config.year), ",
        "or $(kwh(summary.average_daily_energy_kwh)) a day. ",
        "The best month is $(Dates.monthname(best.month)) at $(kwh(best.estimated_energy_kwh)). ",
        "By month: $monthly. This is a clear-sky estimate, not a weather forecast.",
    )
    # The daily results stay out: the monthly summary already shows the seasons.
    structured = JSON.json((; location, config, summary))
    return MCP.StaticMCPToolResult(; text, structured_content=JSON.JSONText(structured))
end

# A stateless server keeps no sessions, so any Soleil process can answer any
# client, and closing a session or opening an event stream is not supported.
const MCP_SERVER = MCP.StaticMCPServer(
    [MCP.StaticMCPTool(;
        name="simulate_solar_exposure",
        title="Simulate Solar Exposure",
        description=string(
            "Estimate clear-sky solar exposure and fixed panel energy production for ",
            "one location and year. Weather, terrain, shading, snow, soiling, ",
            "tracking, inverter clipping, and degradation are not modeled.",
        ),
        input_schema=JSON.JSONText(SIMULATION_ARGUMENTS_SCHEMA),
        annotations=JSON.JSONText("{\"readOnlyHint\":true,\"idempotentHint\":true,\"openWorldHint\":false}"),
        handler=SimulateSolarExposure(),
    )];
    name="Soleil",
    version=string(pkgversion(@__MODULE__)),
    instructions="Use simulate_solar_exposure for annual and seasonal solar estimates.",
    stateless=true,
)

"""
    _register_mcp!(router) -> router

Serve the Model Context Protocol at `POST /mcp`, with one public, read-only
tool: `simulate_solar_exposure`. Other methods get Servo's 405.
"""
function _register_mcp!(router::Servo.Router)
    # Typing the request as `HTTP.Request` lets Servo call the handler statically.
    Servo.register!(router, :POST, "/mcp", (request::Servo.HTTP.Request) -> MCP.handle_static_jsonrpc_request(MCP_SERVER, request); auth=Servo.Public())
    return router
end
