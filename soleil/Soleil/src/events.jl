const WEATHER_STREAM = "SOLEIL_WEATHER"
const WEATHER_SUBJECT = "soleil.weather.advisory"
const WEATHER_CONSUMER = "SOLEIL_WEATHER_WORKERS"
const WEATHER_CLEANUP_JOB = "expire-weather-advisories"
const NANOSECONDS_PER_SECOND = 1_000_000_000

# NATS control-plane calls are request/reply round trips. Give them time on a
# host that is also starting containers or compiling code.
const NATS_TIMEOUT_SECONDS = 10

"""
    GeoBounds(south, west, north, east)

An inclusive latitude/longitude box. Boxes that cross the date line are not
supported.
"""
struct GeoBounds
    south::Float64
    west::Float64
    north::Float64
    east::Float64
end

"""
A weather advisory from an external provider. `starts_at` and `ends_at` are UTC.
The `id` identifies the advisory, so delivering it again replaces the earlier copy.
"""
struct WeatherAdvisory
    id::String
    kind::String
    severity::String
    headline::String
    bounds::GeoBounds
    starts_at::DateTime
    ends_at::DateTime
end

"""
The webhook's answer once NATS JetStream has stored an advisory: its stream
sequence number, and whether JetStream had already seen its id.
"""
struct WeatherAdvisoryReceipt
    event_id::String
    stream_sequence::UInt64
    duplicate::Bool
    accepted_at::DateTime
end

"""The advisories that currently affect a user's stored summary."""
struct WeatherStatus
    user_id::String
    advisories::Vector{WeatherAdvisory}
end

"""
Bearer auth for the weather webhook: providers present the configured secret,
which is separate from user access tokens.
"""
struct WeatherWebhookValidator
    secret::String
end

function Servo.authenticatebearer(
    validator::WeatherWebhookValidator,
    token::AbstractString,
    @nospecialize(_request),
)
    isempty(validator.secret) && return nothing
    return OAuth.secure_compare(token, validator.secret) ? "weather-provider" : nothing
end

"""
The NATS connection, JetStream consumer, worker task, and Tempus scheduler that
process weather advisories. `close` stops them.
"""
struct EventRuntime
    connection::NATS.Connection
    subscription::NATS.JetStream.PullSubscription
    worker::Task
    scheduler::Tempus.Scheduler
    stopping::Threads.Atomic{Bool}
end

"""A running Soleil server, plus its event runtime when events are enabled."""
struct Server{S}
    http::S
    events::Union{Nothing,EventRuntime}
end

Servo.port(server::Server) = Servo.port(server.http)
Base.wait(server::Server) = wait(server.http)

function Base.close(server::Server)
    try
        close(server.http)
    finally
        server.events === nothing || close(server.events)
    end
    return nothing
end

function _required_text(value::String, field::String)
    isempty(strip(value)) && throw(ArgumentError("$field must not be empty"))
    return value
end

function _validate_weather_advisory(advisory::WeatherAdvisory)
    _required_text(advisory.id, "id")
    _required_text(advisory.kind, "kind")
    _required_text(advisory.severity, "severity")
    _required_text(advisory.headline, "headline")
    (; south, west, north, east) = advisory.bounds
    all(isfinite, (south, west, north, east)) ||
        throw(ArgumentError("bounds must be finite"))
    -90 <= south <= north <= 90 ||
        throw(ArgumentError("bounds need -90 <= south <= north <= 90"))
    -180 <= west <= east <= 180 ||
        throw(ArgumentError("bounds need -180 <= west <= east <= 180; boxes cannot cross the date line"))
    advisory.starts_at < advisory.ends_at ||
        throw(ArgumentError("ends_at must be after starts_at"))
    return advisory
end

_contains(bounds::GeoBounds, latitude::Float64, longitude::Float64) =
    bounds.south <= latitude <= bounds.north && bounds.west <= longitude <= bounds.east

function _weather_status(state, user_id::String)
    advisories = get(state.advisories_by_user_id, user_id, WeatherAdvisory[])
    return WeatherStatus(user_id, advisories)
end

# Attach `advisory` to every stored summary inside its bounds, and remove any
# earlier copy of it, so applying an advisory twice changes nothing.
function _apply_weather_advisory!(state, advisory::WeatherAdvisory)
    _validate_weather_advisory(advisory)
    for user_id in keys(state.advisories_by_user_id)
        AbstractStores.modify!(state.advisories_by_user_id, user_id) do current
            current === nothing && return nothing
            remaining = filter(item -> item.id != advisory.id, current)
            return isempty(remaining) ? nothing : remaining
        end
    end
    affected = 0
    for user_id in keys(state.summaries_by_user_id)
        summary = get(state.summaries_by_user_id, user_id, nothing)
        (summary !== nothing && _contains(advisory.bounds, summary.latitude, summary.longitude)) ||
            continue
        AbstractStores.modify!(state.advisories_by_user_id, user_id) do current
            advisories = current === nothing ? WeatherAdvisory[] : copy(current)
            push!(advisories, advisory)
            return sort!(advisories; by=item -> (item.ends_at, item.id))
        end
        affected += 1
    end
    return affected
end

# Remove advisories that ended by `now`; returns how many were removed.
function _expire_weather_advisories!(state, now::DateTime)
    expired = Ref(0)
    for user_id in keys(state.advisories_by_user_id)
        AbstractStores.modify!(state.advisories_by_user_id, user_id) do current
            current === nothing && return nothing
            active = filter(item -> item.ends_at > now, current)
            expired[] += length(current) - length(active)
            return isempty(active) ? nothing : active
        end
    end
    return expired[]
end

function _publish_weather_advisory!(events::Union{Nothing,EventRuntime}, advisory::WeatherAdvisory)
    _validate_weather_advisory(advisory)
    events === nothing && throw(Servo.HTTPError(503, "weather event processing is disabled"))
    # JetStream drops a second message with the same id, so a provider that
    # retries a webhook does not create a second event.
    ack = NATS.JetStream.publish(
        events.connection,
        WEATHER_SUBJECT,
        JSON.json(advisory);
        msg_id=advisory.id,
        expected_stream=WEATHER_STREAM,
        timeout=NATS_TIMEOUT_SECONDS,
    )
    return WeatherAdvisoryReceipt(advisory.id, ack.seq, ack.duplicate, Dates.now(UTC))
end

# Apply one JetStream message, then acknowledge it. An invalid advisory is
# terminated, so it is never redelivered; a failure while applying a valid one
# is negatively acknowledged, so JetStream redelivers it after a second.
function _process_weather_message!(state, connection, message; logging::Bool)
    advisory = try
        _validate_weather_advisory(JSON.parse(NATS.payload(message), WeatherAdvisory))
    catch error
        @error "discarding an invalid weather advisory" exception=(error, catch_backtrace())
        NATS.JetStream.term(connection, message; reason="invalid weather advisory")
        return nothing
    end
    try
        affected = _apply_weather_advisory!(state, advisory)
        NATS.JetStream.ack_sync(connection, message; timeout=NATS_TIMEOUT_SECONDS)
        logging && @info "weather advisory applied" id=advisory.id affected
    catch error
        @error "applying a weather advisory failed" id=advisory.id exception=(error, catch_backtrace())
        NATS.JetStream.nak(connection, message; delay_ns=NANOSECONDS_PER_SECOND)
    end
    return nothing
end

function _weather_worker_loop(state, connection, subscription, stopping, logging::Bool)
    while !stopping[]
        messages = try
            NATS.JetStream.fetch(subscription; batch=16, expires_ns=NANOSECONDS_PER_SECOND ÷ 2, timeout=2)
        catch error
            stopping[] && break
            @error "fetching weather events failed" exception=(error, catch_backtrace())
            sleep(0.25)
            continue
        end
        for message in messages
            stopping[] && break
            try
                _process_weather_message!(state, connection, message; logging)
            catch error
                # Acknowledgements can fail while NATS reconnects. The message
                # stays unacknowledged, so JetStream redelivers it later.
                stopping[] && break
                @error "acknowledging a weather event failed" exception=(error, catch_backtrace())
            end
        end
    end
    return nothing
end

# Create the stream and the durable consumer if they do not exist (or update
# them), then subscribe to the consumer.
function _provision_weather_stream!(connection)
    NATS.JetStream.create_or_update_stream(
        connection,
        NATS.JetStream.StreamConfig(
            name=WEATHER_STREAM,
            subjects=[WEATHER_SUBJECT],
            description="Soleil weather advisories",
            storage="file",
            max_msgs=10_000,
            max_age=7 * 24 * 60 * 60 * NANOSECONDS_PER_SECOND,
            duplicate_window=2 * 60 * NANOSECONDS_PER_SECOND,
        );
        timeout=NATS_TIMEOUT_SECONDS,
    )
    NATS.JetStream.create_or_update_consumer(
        connection,
        WEATHER_STREAM,
        NATS.JetStream.ConsumerConfig(
            name=WEATHER_CONSUMER,
            durable_name=WEATHER_CONSUMER,
            description="Soleil weather advisory workers",
            filter_subject=WEATHER_SUBJECT,
            ack_policy="explicit",
            ack_wait=30 * NANOSECONDS_PER_SECOND,
            max_deliver=5,
            max_ack_pending=64,
        );
        timeout=NATS_TIMEOUT_SECONDS,
    )
    return NATS.JetStream.pull_subscribe(connection, WEATHER_STREAM, WEATHER_CONSUMER; timeout=NATS_TIMEOUT_SECONDS)
end

function _start_event_runtime(state; nats_url::String, cleanup_schedule::String, logging::Bool)
    connection = NATS.connect(nats_url; name="soleil-events")
    subscription = try
        _provision_weather_stream!(connection)
    catch
        NATS.close(connection)
        rethrow()
    end
    scheduler = try
        # Tempus keeps job definitions and run history in the state backend.
        # Adding the job on every start replaces its stored definition and
        # keeps its history.
        store = Tempus.Store(state.backend; prefix="tempus/")
        cleanup = Tempus.Job(
            () -> _expire_weather_advisories!(state, Dates.now(UTC)),
            WEATHER_CLEANUP_JOB,
            cleanup_schedule;
            overlap_policy=:skip,
            retries=0,
        )
        Tempus.addJob!(store, cleanup)
        scheduler = Tempus.Scheduler(store; logging)
        Tempus.run!(scheduler)
        scheduler
    catch
        close(subscription)
        NATS.close(connection)
        rethrow()
    end
    stopping = Threads.Atomic{Bool}(false)
    # A long-running loop belongs on the default thread pool, leaving the
    # interactive pool to NATS's connection tasks.
    worker = Threads.@spawn :default _weather_worker_loop(state, connection, subscription, stopping, logging)
    return EventRuntime(connection, subscription, worker, scheduler, stopping)
end

function Base.close(events::EventRuntime)
    Threads.atomic_xchg!(events.stopping, true) && return nothing
    # Closing the subscription wakes the worker if it is waiting for messages.
    try
        close(events.subscription)
    catch error
        @debug "the weather subscription was already closed" exception=(error, catch_backtrace())
    end
    timedwait(() -> istaskdone(events.worker), 3; pollint=0.01) == :timed_out &&
        @warn "the weather worker did not stop within 3 seconds"
    try
        close(events.scheduler)
    finally
        try
            NATS.drain(events.connection; timeout=NATS_TIMEOUT_SECONDS)
        catch
            NATS.close(events.connection)
        end
    end
    return nothing
end

"""
    _configured_event_runtime(state) -> Union{Nothing,EventRuntime}

Start event processing when `events.enabled` is set, or return `nothing`.
"""
function _configured_event_runtime(state)
    Servo.config("events.enabled", false) || return nothing
    isempty(Servo.config("events.webhook_secret", "")) &&
        throw(ArgumentError("events.webhook_secret must be set when events are enabled"))
    return _start_event_runtime(
        state;
        nats_url=Servo.config("events.nats.url", "nats://127.0.0.1:4222"),
        cleanup_schedule=Servo.config("events.cleanup_schedule", "0 0 * * * *"),
        logging=Servo.config("events.logging", true),
    )
end
