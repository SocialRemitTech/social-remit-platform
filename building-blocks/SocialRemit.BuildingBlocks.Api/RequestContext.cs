using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;
using SocialRemit.BuildingBlocks.Messaging;

namespace SocialRemit.BuildingBlocks.Api;

// ============================================================================
// Request context
//
// Every mobile request carries the headers in Baseline 2.0 §5.1. This middleware
// turns them into one ambient object that flows through handlers, into the outbox,
// and out into events — so a customer-visible interaction has a single correlation
// ID from the tap to the audit record.
//
// X-Device-Installation-Id is a RISK SIGNAL, never an identity proof. It is
// hashed before it touches storage or telemetry.
// ============================================================================

public sealed record RequestContext : IAmbientContext
{
    public required Guid CorrelationId { get; init; }
    public Guid? CausationId { get; init; }
    public string? Traceparent { get; init; }

    public required string AppVersion { get; init; }
    public required string Platform { get; init; }

    /// <summary>Hashed. The raw installation ID is never persisted or logged.</summary>
    public required string DeviceInstallationIdHash { get; init; }

    public string? IdempotencyKey { get; init; }
    public required DateTimeOffset ReceivedAt { get; init; }

    /// <summary>Populated after authentication. Null on unauthenticated routes.</summary>
    public string? CustomerId { get; init; }
    public string? JourneyId { get; init; }
    public string? SessionId { get; init; }

    /// <summary>
    /// Subject key for idempotency scoping. Falls back to the device hash so that an
    /// unauthenticated retry (registration, recovery) is still deduplicated per device
    /// rather than globally, which would let one caller's key collide with another's.
    /// </summary>
    public string IdempotencySubjectKey =>
        CustomerId ?? JourneyId ?? $"dev:{DeviceInstallationIdHash}";
}

public static class SocialRemitHeaders
{
    public const string CorrelationId        = "X-Correlation-Id";
    public const string IdempotencyKey       = "Idempotency-Key";
    public const string AppVersion           = "X-App-Version";
    public const string Platform             = "X-Platform";
    public const string DeviceInstallationId = "X-Device-Installation-Id";
}

public interface IRequestContextAccessor
{
    RequestContext Current { get; }
}

public sealed class RequestContextMiddleware
{
    private static readonly string[] ValidPlatforms = ["ios", "android"];

    private readonly RequestDelegate _next;
    private readonly IErrorCatalogue _errors;
    private readonly TimeProvider _time;
    private readonly string _installationIdPepper;

    public RequestContextMiddleware(
        RequestDelegate next,
        IErrorCatalogue errors,
        TimeProvider time,
        InstallationIdPepper pepper)
    {
        _next = next;
        _errors = errors;
        _time = time;
        _installationIdPepper = pepper.Value;
    }

    public async Task InvokeAsync(HttpContext httpContext, RequestContextHolder holder)
    {
        var headers = httpContext.Request.Headers;

        // Client-supplied correlation IDs are accepted but validated. An unparseable
        // value gets replaced rather than rejected — breaking a customer's registration
        // over a malformed trace header would be the wrong trade.
        var correlationId = Guid.TryParse(headers[SocialRemitHeaders.CorrelationId], out var parsed)
            ? parsed
            : Guid.CreateVersion7();

        var appVersion = headers[SocialRemitHeaders.AppVersion].ToString();
        var platform = headers[SocialRemitHeaders.Platform].ToString().ToLowerInvariant();
        var installationId = headers[SocialRemitHeaders.DeviceInstallationId].ToString();

        var missing = new List<string>();
        if (string.IsNullOrWhiteSpace(appVersion)) missing.Add(SocialRemitHeaders.AppVersion);
        if (!ValidPlatforms.Contains(platform)) missing.Add(SocialRemitHeaders.Platform);
        if (string.IsNullOrWhiteSpace(installationId)) missing.Add(SocialRemitHeaders.DeviceInstallationId);

        if (missing.Count > 0)
        {
            await WriteHeaderValidationFailureAsync(httpContext, correlationId, missing).ConfigureAwait(false);
            return;
        }

        var context = new RequestContext
        {
            CorrelationId            = correlationId,
            CausationId              = null,
            Traceparent              = Activity.Current?.Id,
            AppVersion               = appVersion,
            Platform                 = platform,
            DeviceInstallationIdHash = HashInstallationId(installationId),
            IdempotencyKey           = headers[SocialRemitHeaders.IdempotencyKey].ToString() is { Length: > 0 } key
                                       ? key : null,
            ReceivedAt               = _time.GetUtcNow()
        };

        holder.Set(context);

        // Echo it back so the app can attach the correlation ID to a support request.
        httpContext.Response.Headers[SocialRemitHeaders.CorrelationId] = correlationId.ToString();

        // Surfaced on every log line and span emitted during this request.
        Activity.Current?.SetTag("sr.correlation_id", correlationId);
        Activity.Current?.SetTag("sr.app_version", appVersion);
        Activity.Current?.SetTag("sr.platform", platform);

        await _next(httpContext).ConfigureAwait(false);
    }

    /// <summary>
    /// HMAC rather than a plain hash: an installation ID has low entropy in aggregate,
    /// and a keyed digest stops anyone with database read access from re-deriving it
    /// by brute force. The pepper lives in Secrets Manager, not configuration.
    /// </summary>
    private string HashInstallationId(string installationId)
    {
        var key = Encoding.UTF8.GetBytes(_installationIdPepper);
        var value = Encoding.UTF8.GetBytes(installationId);
        return Convert.ToHexStringLower(HMACSHA256.HashData(key, value));
    }

    private async Task WriteHeaderValidationFailureAsync(
        HttpContext httpContext, Guid correlationId, IReadOnlyList<string> missingHeaders)
    {
        _errors.TryGet(ErrorCodes.ValidationFailed, out var definition);

        httpContext.Response.StatusCode = definition.HttpStatus;
        httpContext.Response.ContentType = "application/json";
        httpContext.Response.Headers[SocialRemitHeaders.CorrelationId] = correlationId.ToString();

        var body = new ApiResponse<object>
        {
            Data = null,
            Meta = new ApiMeta { CorrelationId = correlationId, ServerTime = _time.GetUtcNow() },
            Error = new ApiError
            {
                Code = definition.Code,
                CopyKey = definition.CopyKey,
                Retryable = false,
                Details = new Dictionary<string, object?> { ["missingHeaders"] = missingHeaders }
            }
        };

        await httpContext.Response.WriteAsJsonAsync(body).ConfigureAwait(false);
    }
}

/// <summary>Scoped holder so the context is available to handlers via DI.</summary>
public sealed class RequestContextHolder : IRequestContextAccessor
{
    private RequestContext? _context;

    public RequestContext Current =>
        _context ?? throw new InvalidOperationException(
            "RequestContext is not set. RequestContextMiddleware must run before anything that resolves it.");

    public void Set(RequestContext context) => _context = context;

    public void Enrich(Func<RequestContext, RequestContext> mutate) => _context = mutate(Current);
}

/// <summary>Typed wrapper so the pepper cannot be injected as a bare string by accident.</summary>
public sealed record InstallationIdPepper(string Value);
