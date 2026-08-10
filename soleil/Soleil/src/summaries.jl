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
    lock(state.lock) do
        haskey(state.summaries_by_user_id, user_id) &&
            throw(Servo.HTTPError(409, "a stored summary already exists"))
        state.summaries_by_user_id[user_id] = stored
    end
    return stored
end

function _get_summary(state, user_id::String)
    stored = lock(() -> get(state.summaries_by_user_id, user_id, nothing), state.lock)
    stored === nothing && Servo.notfound("no stored summary exists")
    return stored
end

function _update_summary!(state, user_id::String, input::SimulationRequest)
    stored = _stored_summary(user_id, input)
    lock(state.lock) do
        haskey(state.summaries_by_user_id, user_id) ||
            Servo.notfound("no stored summary exists")
        state.summaries_by_user_id[user_id] = stored
    end
    return stored
end

function _delete_summary!(state, user_id::String)
    removed = lock(() -> pop!(state.summaries_by_user_id, user_id, nothing), state.lock)
    removed === nothing && Servo.notfound("no stored summary exists")
    return nothing
end
