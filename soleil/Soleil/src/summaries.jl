"""The inputs for creating or replacing a user's stored summary."""
struct SimulationRequest
    latitude::Float64
    longitude::Float64
    year::Int
    system_capacity_kw::Float64
end

"""A user's stored solar summary."""
struct StoredSolarSummary
    user_id::String
    latitude::Float64
    longitude::Float64
    year::Int
    system_capacity_kw::Float64
    updated_at::DateTime
    summary::Solar.SolarSummary
end

function _stored_summary(user_id::String, input::SimulationRequest)
    simulation = Solar.simulate(
        input.latitude,
        input.longitude;
        year=input.year,
        system_capacity_kw=input.system_capacity_kw,
    )
    return StoredSolarSummary(
        user_id,
        input.latitude,
        input.longitude,
        input.year,
        input.system_capacity_kw,
        Dates.now(UTC),
        simulation.summary,
    )
end

function _create_summary!(state, user_id::String, input::SimulationRequest)
    stored = _stored_summary(user_id, input)
    AbstractStores.modify!(state.summaries_by_user_id, user_id) do current
        current === nothing ||
            throw(Servo.HTTPError(409, "a stored summary already exists"))
        return stored
    end
    # Weather advisories matched an earlier summary's location, so drop them.
    pop!(state.advisories_by_user_id, user_id, nothing)
    return stored
end

function _get_summary(state, user_id::String)
    stored = get(state.summaries_by_user_id, user_id, nothing)
    stored === nothing && Servo.notfound("no stored summary exists")
    return stored
end

function _update_summary!(state, user_id::String, input::SimulationRequest)
    stored = _stored_summary(user_id, input)
    AbstractStores.modify!(state.summaries_by_user_id, user_id) do current
        current === nothing && Servo.notfound("no stored summary exists")
        return stored
    end
    pop!(state.advisories_by_user_id, user_id, nothing)
    return stored
end

function _delete_summary!(state, user_id::String)
    removed = pop!(state.summaries_by_user_id, user_id, nothing)
    removed === nothing && Servo.notfound("no stored summary exists")
    pop!(state.advisories_by_user_id, user_id, nothing)
    return nothing
end
