using System.Text.Json.Serialization;

namespace SocialRemit.BuildingBlocks.Api;

// ============================================================================
// The public response envelope (Baseline 2.0 §5.2).
//
// Every mobile response has the same shape: { data, meta, error }. The client
// renders meta.journeyState and meta.nextActions and does not infer where the
// customer is from which screens it has shown.
//
// The server never sends customer-facing prose. It sends a stable code and a
// copyKey. This is what makes localisation, copy review and legal sign-off
// possible without a backend deploy — and it is what stops a FinCode error
// string reaching a customer.
// ============================================================================

public sealed record ApiResponse<T>
{
    [JsonPropertyName("data")]  public T? Data { get; init; }
    [JsonPropertyName("meta")]  public required ApiMeta Meta { get; init; }
    [JsonPropertyName("error")] public ApiError? Error { get; init; }
}

public sealed record ApiMeta
{
    [JsonPropertyName("correlationId")] public required Guid CorrelationId { get; init; }

    [JsonPropertyName("journeyState")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? JourneyState { get; init; }

    [JsonPropertyName("nextActions")] public IReadOnlyList<NextAction> NextActions { get; init; } = [];

    [JsonPropertyName("serverTime")] public required DateTimeOffset ServerTime { get; init; }
}

public sealed record NextAction
{
    [JsonPropertyName("action")] public required string Action { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [JsonPropertyName("params")] public IReadOnlyDictionary<string, object?>? Params { get; init; }
}

public sealed record ApiError
{
    [JsonPropertyName("code")]    public required string Code { get; init; }
    [JsonPropertyName("copyKey")] public required string CopyKey { get; init; }
    [JsonPropertyName("retryable")] public bool Retryable { get; init; }

    /// <summary>
    /// Non-sensitive metadata only: attemptsRemaining, retryAfterSeconds, reasonCategory,
    /// requiredFactors, fieldErrors. Never the submitted value, never a destination in full,
    /// never a provider message.
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [JsonPropertyName("details")] public IReadOnlyDictionary<string, object?>? Details { get; init; }
}

/// <summary>
/// Generated from contracts/errors/error-catalogue.json at build time.
/// Hand-editing this file is a CI failure — change the catalogue instead, so the
/// client, the copy deck and the server can never disagree about what a code means.
/// </summary>
public static class ErrorCodes
{
    public const string AppVersionUnsupported        = "APP_VERSION_UNSUPPORTED";
    public const string MaintenanceMode              = "MAINTENANCE_MODE";
    public const string ProspectRequired             = "PROSPECT_REQUIRED";
    public const string JourneyExpired               = "JOURNEY_EXPIRED";
    public const string JourneyStateConflict         = "JOURNEY_STATE_CONFLICT";
    public const string OtpInvalid                   = "OTP_INVALID";
    public const string OtpExpired                   = "OTP_EXPIRED";
    public const string OtpSuperseded                = "OTP_SUPERSEDED";
    public const string OtpAttemptsExhausted         = "OTP_ATTEMPTS_EXHAUSTED";
    public const string ResendTooSoon                = "RESEND_TOO_SOON";
    public const string RateLimited                  = "RATE_LIMITED";
    public const string PasscodeMismatch             = "PASSCODE_MISMATCH";
    public const string PasscodeWeak                 = "PASSCODE_WEAK";
    public const string PasscodeInvalid              = "PASSCODE_INVALID";
    public const string PasscodeCooldown             = "PASSCODE_COOLDOWN";
    public const string DeviceUnrecognized           = "DEVICE_UNRECOGNIZED";
    public const string AuthenticationStepUpRequired = "AUTHENTICATION_STEP_UP_REQUIRED";
    public const string SessionExpired               = "SESSION_EXPIRED";
    public const string RecoveryEmailUnverified      = "RECOVERY_EMAIL_UNVERIFIED";
    public const string RecoveryManualRequired       = "RECOVERY_MANUAL_REQUIRED";
    public const string RiskReviewRequired           = "RISK_REVIEW_REQUIRED";
    public const string AccountRestricted            = "ACCOUNT_RESTRICTED";
    public const string IdempotencyKeyReused         = "IDEMPOTENCY_KEY_REUSED";
    public const string IdempotentRequestInProgress  = "IDEMPOTENT_REQUEST_IN_PROGRESS";
    public const string ValidationFailed             = "VALIDATION_FAILED";
    public const string ServiceUnavailable           = "SERVICE_UNAVAILABLE";
    public const string SetupCompleting              = "SETUP_COMPLETING";
}

/// <summary>
/// The catalogue entry for a code: HTTP status, copy key and retryability.
/// Loaded once from the embedded catalogue so a handler cannot invent a mapping.
/// </summary>
public interface IErrorCatalogue
{
    bool TryGet(string code, out ErrorDefinition definition);
}

public sealed record ErrorDefinition(string Code, int HttpStatus, string CopyKey, bool Retryable);

/// <summary>
/// Domain failure that maps onto a catalogue code. Services throw this rather than
/// constructing HTTP responses, so the mapping to status codes stays in one place.
/// </summary>
public sealed class SocialRemitException : Exception
{
    public string Code { get; }
    public IReadOnlyDictionary<string, object?>? Details { get; }

    public SocialRemitException(
        string code,
        IReadOnlyDictionary<string, object?>? details = null,
        Exception? innerException = null)
        : base(code, innerException)
    {
        Code = code;
        Details = details;
    }
}

public static class ApiResults
{
    public static ApiResponse<T> Ok<T>(
        T data,
        RequestContext context,
        string? journeyState = null,
        IReadOnlyList<NextAction>? nextActions = null) => new()
    {
        Data = data,
        Meta = new ApiMeta
        {
            CorrelationId = context.CorrelationId,
            JourneyState  = journeyState,
            NextActions   = nextActions ?? [],
            ServerTime    = context.ReceivedAt
        },
        Error = null
    };

    public static ApiResponse<object> Failure(
        ErrorDefinition definition,
        RequestContext context,
        IReadOnlyDictionary<string, object?>? details = null,
        string? journeyState = null) => new()
    {
        Data = null,
        Meta = new ApiMeta
        {
            CorrelationId = context.CorrelationId,
            JourneyState  = journeyState,
            ServerTime    = context.ReceivedAt
        },
        Error = new ApiError
        {
            Code      = definition.Code,
            CopyKey   = definition.CopyKey,
            Retryable = definition.Retryable,
            Details   = details
        }
    };
}
