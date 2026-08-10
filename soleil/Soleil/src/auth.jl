# Verification rejects a token unless its `iss` (issuer) and `aud` (audience)
# claims match these. The `kid` header names the key that signed a token, which
# lets a verifier pick the right key when keys rotate.
const TOKEN_ISSUER = "https://soleil.local"
const TOKEN_AUDIENCE = "soleil-api"
const TOKEN_KEY_ID = "soleil-local"
const TOKEN_LIFETIME_SECONDS = 60 * 60
const PASSWORD_SALT_BYTES = 16

"""The email and password for account creation and login. Never returned."""
struct Credentials
    email::String
    password::String
end

"""An account as the API returns it, without password material."""
struct Account
    id::String
    email::String
    created_at::DateTime
end

"""The bearer token returned by a successful login."""
struct LoginResponse
    access_token::String
    token_type::String
    expires_in::Int
    scope::String
    user_id::String
end

"""
A stored account. The salted SHA-256 digest keeps this example free of extra
dependencies, but it is not a password hash: use Argon2id, scrypt, or bcrypt in
production.
"""
struct User
    id::String
    email::String
    password_salt::Vector{UInt8}
    password_digest::Vector{UInt8}
    created_at::DateTime
end

"""
The claims in a Soleil access token: the registered JWT claims OAuth.jl sets,
its `client_id` and `scope`, and Soleil's `email`. Verified tokens decode into
this struct, so every claim is a typed field.
"""
Base.@kwdef struct SoleilTokenClaims
    iss::Union{Nothing,String} = nothing
    aud::Union{Nothing,String} = nothing # Soleil issues tokens for one audience
    exp::Union{Nothing,Int64} = nothing
    iat::Union{Nothing,Int64} = nothing
    jti::Union{Nothing,String} = nothing
    sub::Union{Nothing,String} = nothing
    client_id::Union{Nothing,String} = nothing
    scope::Union{Nothing,String} = nothing
    email::Union{Nothing,String} = nothing
end

"""What a private endpoint gets from `Servo.principal()`."""
struct AuthContext
    access_token::String
    user::Account
    claims::SoleilTokenClaims
end

"""
The state every endpoint shares: accounts, stored summaries, and the token
service and verifier. Each record type is a typed, prefixed view of one
AbstractStores `backend`, so the whole state lives in one place.
"""
struct ApplicationState{B<:AbstractStores.AbstractStore,T<:OAuth.TokenService,V<:JWTs.Verifier}
    backend::B
    users_by_id::AbstractStores.PrefixedStore{User,B}
    user_ids_by_email::AbstractStores.PrefixedStore{String,B}
    summaries_by_user_id::AbstractStores.PrefixedStore{StoredSolarSummary,B}
    advisories_by_user_id::AbstractStores.PrefixedStore{Vector{WeatherAdvisory},B}
    token_service::T
    token_verifier::V
end

function _new_application_state(backend::AbstractStores.AbstractStore=AbstractStores.MemoryStore())
    # The signing key is stored too, so tokens stay valid across restarts.
    metadata = AbstractStores.PrefixedStore{String}(backend, "soleil/meta/")
    private_key = get!(OAuth.generate_rsa_private_key, metadata, "jwt-private-key")
    token_issuer = OAuth.JWTAccessTokenIssuer(;
        issuer=TOKEN_ISSUER,
        audience=[TOKEN_AUDIENCE],
        # Passing a signer, not just a key, gives the issuer a concrete type.
        signer=OAuth.rsa_signer_from_bytes(private_key),
        alg=:RS256,
        kid=TOKEN_KEY_ID,
        expires_in=TOKEN_LIFETIME_SECONDS,
    )
    token_verifier = JWTs.Verifier(
        SoleilTokenClaims,
        [OAuth.public_jwk(token_issuer)];
        algorithms=["RS256"],
        issuer=TOKEN_ISSUER,
        audience=TOKEN_AUDIENCE,
        leeway=5,
        required_claims=["sub", "exp", "iat", "jti"],
    )
    # The token service records every token it issues, so authentication can
    # reject tokens it never issued or has revoked. Soleil issues no refresh
    # tokens, so their store stays empty.
    token_service = OAuth.TokenService(;
        issuer=token_issuer,
        access_tokens=AbstractStores.PrefixedStore{OAuth.AccessTokenRecord{SoleilTokenClaims}}(
            backend,
            "oauth/access/",
        ),
        refresh_grants=OAuth.InMemoryRefreshTokenGrantStore(),
    )
    return ApplicationState(
        backend,
        AbstractStores.PrefixedStore{User}(backend, "soleil/users/id/"),
        AbstractStores.PrefixedStore{String}(backend, "soleil/users/email/"),
        AbstractStores.PrefixedStore{StoredSolarSummary}(backend, "soleil/summaries/"),
        AbstractStores.PrefixedStore{Vector{WeatherAdvisory}}(backend, "soleil/weather/"),
        token_service,
        token_verifier,
    )
end

_account(user::User) = Account(user.id, user.email, user.created_at)

function _normalize_email(email::AbstractString)
    normalized = lowercase(strip(String(email)))
    isempty(normalized) && Servo.badrequest("email must not be empty")
    occursin('@', normalized) || Servo.badrequest("email must contain an @ sign")
    return normalized
end

function _validate_password(password::AbstractString)
    isempty(password) && Servo.badrequest("password must not be empty")
    return String(password)
end

_password_digest(password::String, salt::Vector{UInt8}) =
    SHA.sha256(vcat(salt, codeunits(password)))

# Emails are hashed before they become store keys, so file names and Redis keys
# do not reveal them.
_email_key(email::String) = bytes2hex(SHA.sha256(email))

function _create_account!(state::ApplicationState, credentials::Credentials)
    email = _normalize_email(credentials.email)
    password = _validate_password(credentials.password)
    salt = rand(Random.RandomDevice(), UInt8, PASSWORD_SALT_BYTES)
    # A 128-bit random id, written compactly in Base58 for URLs.
    id = string(Encid.UID(; uid_type=Encid.UID16))
    user = User(id, email, salt, _password_digest(password, salt), Dates.now(UTC))
    # Reserve the email first: `modify!` lets only one request claim it.
    email_key = _email_key(email)
    AbstractStores.modify!(state.user_ids_by_email, email_key) do current
        current === nothing ||
            throw(Servo.HTTPError(409, "an account already exists for this email"))
        return user.id
    end
    try
        state.users_by_id[user.id] = user
    catch
        # Release only this request's reservation.
        AbstractStores.modify!(state.user_ids_by_email, email_key) do current
            current == user.id ? nothing : current
        end
        rethrow()
    end
    return _account(user)
end

function _find_user_by_email(state::ApplicationState, email::String)
    user_id = get(state.user_ids_by_email, _email_key(email), nothing)
    return user_id === nothing ? nothing : get(state.users_by_id, user_id, nothing)
end

function _login!(state::ApplicationState, credentials::Credentials)
    email = _normalize_email(credentials.email)
    password = _validate_password(credentials.password)
    user = _find_user_by_email(state, email)
    (
        user === nothing ||
        !OAuth.secure_compare(_password_digest(password, user.password_salt), user.password_digest)
    ) && Servo.unauthorized("invalid email or password")

    # The issuer adds `iss`, `aud`, `iat`, and `exp`; `sub` names the user.
    issued = OAuth.issue_access_token(
        state.token_service;
        subject=user.id,
        client_id="soleil-client",
        scope=["solar:read", "solar:write"],
        extra_claims=Dict{String,Any}("email" => user.email),
    )
    return LoginResponse(
        issued.token,
        "Bearer",
        TOKEN_LIFETIME_SECONDS,
        join(issued.scope, ' '),
        user.id,
    )
end

"""
Soleil's token check for `Servo.BearerAuth`. JWTs.jl verifies the signature and
claims, then OAuth.jl confirms that Soleil issued the token and has not revoked
it. The resulting [`AuthContext`](@ref) becomes `Servo.principal()`.
"""
struct SoleilTokenValidator{S<:ApplicationState}
    state::S
end

function Servo.authenticatebearer(
    validator::SoleilTokenValidator,
    token::AbstractString,
    @nospecialize(_request),
)
    state = validator.state
    token = String(token)
    claims = try
        JWTs.claims(JWTs.verify(state.token_verifier, token))
    catch error
        error isa JWTs.JWTError || rethrow()
        return nothing
    end
    user_id = claims.sub
    user_id === nothing && return nothing
    record = OAuth.lookup_access_token(state.token_service, token)
    (record === nothing || record.revoked || record.subject != user_id) && return nothing
    user = get(state.users_by_id, user_id, nothing)
    user === nothing && return nothing
    return AuthContext(token, _account(user), claims)
end

# The authenticated user's id when they own the account `user_id`; a 403 otherwise.
function _owner(user_id::AbstractString)
    context = Servo.principal()
    context isa AuthContext || Servo.unauthorized()
    context.user.id == user_id ||
        Servo.forbidden("the authenticated user cannot access this account")
    return context.user.id
end
