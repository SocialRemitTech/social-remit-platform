using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace SocialRemit.BuildingBlocks.Api;

// ============================================================================
// Idempotency
//
// Baseline 2.0 §2.1.6: every state-changing request must support idempotency.
//
// Mobile networks retry. A customer taps Confirm twice. ECS restarts mid-request.
// Without this, "resend OTP" issues two codes and invalidates the one the customer
// is looking at, and later in the programme, "confirm transfer" takes money twice.
//
// Scope is (key, route, subject). A key reused on a different route or by a
// different subject is a client bug, and we surface it rather than replay an
// unrelated response.
// ============================================================================

public sealed record IdempotencyRecord
{
    public required string Status { get; init; }        // IN_PROGRESS | COMPLETED | FAILED
    public required byte[] RequestHash { get; init; }
    public int? ResponseStatus { get; init; }
    public string? ResponseBody { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
}

public interface IIdempotencyStore
{
    /// <summary>
    /// Attempts to claim the key. Returns null if claimed (this is the first execution),
    /// or the existing record if the key was already used.
    /// Implemented as INSERT ... ON CONFLICT DO NOTHING RETURNING — one round trip,
    /// no read-then-write race between two concurrent retries.
    /// </summary>
    Task<IdempotencyRecord?> TryClaimAsync(
        string key, string routeKey, string subjectKey, byte[] requestHash,
        Guid correlationId, DateTimeOffset expiresAt, CancellationToken ct);

    Task CompleteAsync(
        string key, string routeKey, string subjectKey,
        int responseStatus, string responseBody, CancellationToken ct);

    Task ReleaseAsync(string key, string routeKey, string subjectKey, CancellationToken ct);
}

public sealed class IdempotencyOptions
{
    public TimeSpan Retention { get; set; } = TimeSpan.FromHours(24);

    /// <summary>
    /// How long a concurrent caller is told to wait when the original request is
    /// still running. Deliberately short: the client is usually a retry of the
    /// very request still in flight.
    /// </summary>
    public int InProgressRetryAfterSeconds { get; set; } = 2;
}

/// <summary>
/// Middleware form so it applies uniformly, including to minimal-API endpoints.
/// Register it AFTER RequestContextMiddleware and AFTER authentication, because the
/// subject key depends on both.
/// </summary>
public sealed partial class IdempotencyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly IIdempotencyStore _store;
    private readonly IErrorCatalogue _errors;
    private readonly IdempotencyOptions _options;
    private readonly TimeProvider _time;
    private readonly ILogger<IdempotencyMiddleware> _logger;

    private static readonly string[] StateChangingMethods = ["POST", "PUT", "PATCH", "DELETE"];

    public IdempotencyMiddleware(
        RequestDelegate next,
        IIdempotencyStore store,
        IErrorCatalogue errors,
        IdempotencyOptions options,
        TimeProvider time,
        ILogger<IdempotencyMiddleware> logger)
    {
        _next = next;
        _store = store;
        _errors = errors;
        _options = options;
        _time = time;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext httpContext, RequestContextHolder holder)
    {
        if (!StateChangingMethods.Contains(httpContext.Request.Method))
        {
            await _next(httpContext).ConfigureAwait(false);
            return;
        }

        var context = holder.Current;

        if (string.IsNullOrWhiteSpace(context.IdempotencyKey))
        {
            await WriteErrorAsync(httpContext, context, ErrorCodes.ValidationFailed,
                new Dictionary<string, object?> { ["missingHeaders"] = new[] { SocialRemitHeaders.IdempotencyKey } })
                .ConfigureAwait(false);
            return;
        }

        var routeKey = $"{httpContext.Request.Method} {httpContext.Request.Path}";
        var subjectKey = context.IdempotencySubjectKey;
        var requestHash = await ComputeRequestHashAsync(httpContext).ConfigureAwait(false);

        var existing = await _store.TryClaimAsync(
            context.IdempotencyKey, routeKey, subjectKey, requestHash,
            context.CorrelationId, _time.GetUtcNow() + _options.Retention,
            httpContext.RequestAborted).ConfigureAwait(false);

        if (existing is not null)
        {
            await HandleExistingAsync(httpContext, context, existing, requestHash).ConfigureAwait(false);
            return;
        }

        // First execution. Capture the response so a retry can replay it byte for byte.
        var originalBody = httpContext.Response.Body;
        using var buffer = new MemoryStream();
        httpContext.Response.Body = buffer;

        try
        {
            await _next(httpContext).ConfigureAwait(false);

            buffer.Position = 0;
            var responseBody = await new StreamReader(buffer).ReadToEndAsync().ConfigureAwait(false);

            // Only successful outcomes are memoised. Replaying a 500 would pin a
            // transient failure to the key for its whole retention window — the
            // customer would be stuck until it expired.
            if (httpContext.Response.StatusCode < 500)
            {
                await _store.CompleteAsync(
                    context.IdempotencyKey, routeKey, subjectKey,
                    httpContext.Response.StatusCode, responseBody, CancellationToken.None)
                    .ConfigureAwait(false);
            }
            else
            {
                await _store.ReleaseAsync(context.IdempotencyKey, routeKey, subjectKey, CancellationToken.None)
                            .ConfigureAwait(false);
            }

            buffer.Position = 0;
            await buffer.CopyToAsync(originalBody).ConfigureAwait(false);
        }
        catch
        {
            await _store.ReleaseAsync(context.IdempotencyKey, routeKey, subjectKey, CancellationToken.None)
                        .ConfigureAwait(false);
            throw;
        }
        finally
        {
            httpContext.Response.Body = originalBody;
        }
    }

    private async Task HandleExistingAsync(
        HttpContext httpContext, RequestContext context, IdempotencyRecord existing, byte[] requestHash)
    {
        if (!CryptographicOperations.FixedTimeEquals(existing.RequestHash, requestHash))
        {
            LogKeyReused(context.IdempotencyKey!, httpContext.Request.Path.ToString());
            await WriteErrorAsync(httpContext, context, ErrorCodes.IdempotencyKeyReused).ConfigureAwait(false);
            return;
        }

        if (existing.Status == "IN_PROGRESS")
        {
            await WriteErrorAsync(httpContext, context, ErrorCodes.IdempotentRequestInProgress,
                new Dictionary<string, object?> { ["retryAfterSeconds"] = _options.InProgressRetryAfterSeconds })
                .ConfigureAwait(false);
            return;
        }

        // Replay. Same status, same body. The client cannot tell this apart from the
        // original — which is the entire point.
        httpContext.Response.StatusCode = existing.ResponseStatus ?? StatusCodes.Status200OK;
        httpContext.Response.ContentType = "application/json";
        httpContext.Response.Headers["Idempotent-Replay"] = "true";
        await httpContext.Response.WriteAsync(existing.ResponseBody ?? "{}").ConfigureAwait(false);
    }

    private static async Task<byte[]> ComputeRequestHashAsync(HttpContext httpContext)
    {
        httpContext.Request.EnableBuffering();
        using var sha = SHA256.Create();
        var hash = await sha.ComputeHashAsync(httpContext.Request.Body).ConfigureAwait(false);
        httpContext.Request.Body.Position = 0;
        return hash;
    }

    private async Task WriteErrorAsync(
        HttpContext httpContext, RequestContext context, string code,
        IReadOnlyDictionary<string, object?>? details = null)
    {
        _errors.TryGet(code, out var definition);

        httpContext.Response.StatusCode = definition.HttpStatus;
        httpContext.Response.ContentType = "application/json";

        await httpContext.Response.WriteAsync(
            JsonSerializer.Serialize(ApiResults.Failure(definition, context, details)))
            .ConfigureAwait(false);
    }

    [LoggerMessage(Level = LogLevel.Warning,
        Message = "Idempotency key {IdempotencyKey} reused with a different body on {Path}. Client must generate a new key per distinct intent.")]
    private partial void LogKeyReused(string idempotencyKey, string path);
}
