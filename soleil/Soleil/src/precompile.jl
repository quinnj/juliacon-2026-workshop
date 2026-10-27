# While Soleil precompiles, PrecompileTools runs this workload: one request to
# every endpoint, so the compiled code lands in Soleil's package image and the
# first real request does not wait for the compiler.

function _expect(status::Int, response)
    response.status == status ||
        error("a precompile request answered $(response.status), not $status")
    return response
end

function _precompile_endpoints()
    secret = "precompile-weather-secret"
    empty!(Servo.CONFIG)
    Servo.loadconfig!(; configs=Dict{String,Any}("events" => Dict{String,Any}("webhook_secret" => secret)), log=false)
    mktempdir() do directory
        state = _new_application_state(AbstractStores.FileStore(directory; codec=AbstractStores.JSONCodec()))
        router = _register_mcp!(_register_endpoints!(Servo.Router(), state))
        OpenAPI.register!(router, OPENAPI_JSON)
        Servo.registerbuiltins!(router)
        server = Servo.serve!(router; host="127.0.0.1", port=0, cors=true, accesslog=true)
        base = "http://127.0.0.1:$(Servo.port(server))"
        function request(method, path, body=nothing; token=nothing)
            headers = ["Content-Type" => "application/json"]
            token === nothing || push!(headers, "Authorization" => "Bearer $token")
            payload = body === nothing ? "" : JSON.json(body)
            return Servo.HTTP.request(method, base * path, headers, payload; status_exception=false)
        end
        try
            _expect(200, request("GET", "/status"))
            _expect(200, request("GET", "/openapi.json"))
            _expect(204, request("OPTIONS", "/v1/simulate/40.76/-111.89"))
            _expect(200, request("GET", "/v1/simulate/40.76/-111.89?system_capacity_kw=8.0"))
            _expect(400, request("GET", "/v1/simulate/95.0/-111.89"))

            credentials = Credentials("precompile@example.invalid", "precompile-only-password")
            account = JSON.parse(_expect(200, request("POST", "/v1/accounts", credentials)).body, Account)
            token = JSON.parse(_expect(200, request("POST", "/v1/login", credentials)).body, LoginResponse).access_token
            summary = "/v1/simulate/$(account.id)"
            input = SimulationRequest(40.76, -111.89, 2026, 8.0)
            _expect(200, request("POST", summary, input; token))
            _expect(200, request("GET", summary; token))
            _expect(200, request("PUT", summary, input; token))
            _expect(200, request("GET", "/v1/weather/$(account.id)"; token))

            # Events are not running here, so a valid advisory gets the 503.
            now = DateTime(2026, 6, 1, 18)
            bounds = GeoBounds(37.0, -114.1, 42.1, -109.0)
            advisory = WeatherAdvisory("precompile", "hail", "severe", "Hail", bounds, now, now + Hour(1))
            _expect(503, request("POST", "/v1/webhooks/weather-advisories", advisory; token=secret))
            _expect(204, request("DELETE", summary; token))

            for (method, params) in (
                ("initialize", (; protocolVersion="2025-11-25", capabilities=(;), clientInfo=(; name="precompile", version="1"))),
                ("tools/list", (;)),
                ("tools/call", (; name="simulate_solar_exposure", arguments=(; latitude=40.76, longitude=-111.89))),
            )
                _expect(200, request("POST", "/mcp", (; jsonrpc="2.0", id=1, method, params)))
            end
        finally
            close(server)
        end
    end
    empty!(Servo.CONFIG)
    return nothing
end

@setup_workload begin
    # Format the access log to nowhere: the code compiles, the output stays quiet.
    @compile_workload Logging.with_logger(_precompile_endpoints, Logging.ConsoleLogger(devnull))
end
