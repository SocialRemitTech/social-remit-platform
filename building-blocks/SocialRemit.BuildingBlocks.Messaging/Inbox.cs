using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace SocialRemit.BuildingBlocks.Messaging;

// ============================================================================
// Consumer inbox
//
// Delivery is at-least-once and unordered. Every consumer must therefore tolerate
// duplicate, delayed and out-of-order messages (Baseline 2.0 §2.1.10).
//
// Deduplication is by eventId, recorded in the SAME transaction as the effect.
// Recording it afterwards leaves a window where the effect is applied and the
// evidence is not — which on redelivery applies the effect twice.
// ============================================================================

public enum InboxOutcome
{
    /// <summary>Handled. Evidence committed.</summary>
    Processed,

    /// <summary>Already seen, or not applicable to this consumer. No effect applied.</summary>
    Skipped,

    /// <summary>Transient failure. Return to the queue for retry.</summary>
    RetryLater,

    /// <summary>Permanently unprocessable. Send straight to the DLQ; retrying cannot help.</summary>
    DeadLetter
}

public interface IInboxStore
{
    /// <summary>
    /// Reserves (eventId, consumer). Returns false if the pair already exists —
    /// that is the duplicate signal. Uses INSERT ... ON CONFLICT DO NOTHING.
    /// </summary>
    Task<bool> TryBeginAsync(EventEnvelope envelope, string consumer, CancellationToken ct);

    Task CompleteAsync(Guid eventId, string consumer, InboxOutcome outcome, CancellationToken ct);

    Task RecordFailureAsync(Guid eventId, string consumer, string error, CancellationToken ct);
}

/// <summary>
/// A handler for one event type. Lives in the owning service. The handler applies its
/// effect and the inbox evidence inside one transaction — see IInboxTransactionScope.
/// </summary>
public interface IEventHandler
{
    string EventType { get; }

    /// <summary>Versions this handler understands. An unknown version is a DeadLetter, not a crash.</summary>
    IReadOnlySet<int> SupportedVersions { get; }

    Task<InboxOutcome> HandleAsync(EventEnvelope envelope, CancellationToken ct);
}

/// <summary>
/// Dispatches an inbound envelope to the right handler with dedupe applied.
/// Transport-agnostic: an SQS pump, a test harness, or a replay tool all call this.
/// </summary>
public sealed partial class InboxDispatcher
{
    private readonly IReadOnlyDictionary<string, IEventHandler> _handlers;
    private readonly IInboxStore _store;
    private readonly string _consumerName;
    private readonly ILogger<InboxDispatcher> _logger;

    public InboxDispatcher(
        IEnumerable<IEventHandler> handlers,
        IInboxStore store,
        string consumerName,
        ILogger<InboxDispatcher> logger)
    {
        _handlers = handlers.ToDictionary(h => h.EventType, StringComparer.Ordinal);
        _store = store;
        _consumerName = consumerName;
        _logger = logger;
    }

    public async Task<InboxOutcome> DispatchAsync(EventEnvelope envelope, CancellationToken ct = default)
    {
        if (!_handlers.TryGetValue(envelope.EventType, out var handler))
        {
            // Subscribed to something we do not handle. This is a topology mistake,
            // not a data problem — skip rather than dead-letter so the queue drains,
            // and let the subscription-drift alarm surface it.
            LogUnsubscribedEvent(envelope.EventType, _consumerName);
            await _store.CompleteAsync(envelope.EventId, _consumerName, InboxOutcome.Skipped, ct)
                        .ConfigureAwait(false);
            return InboxOutcome.Skipped;
        }

        if (!handler.SupportedVersions.Contains(envelope.EventVersion))
        {
            // A producer shipped a new major version before this consumer was updated.
            // Dead-letter deliberately: silently ignoring it would lose a real fact,
            // and guessing at the new shape is worse.
            LogUnsupportedVersion(envelope.EventType, envelope.EventVersion, _consumerName);
            await _store.CompleteAsync(envelope.EventId, _consumerName, InboxOutcome.DeadLetter, ct)
                        .ConfigureAwait(false);
            return InboxOutcome.DeadLetter;
        }

        var isFirstDelivery = await _store.TryBeginAsync(envelope, _consumerName, ct).ConfigureAwait(false);
        if (!isFirstDelivery)
        {
            // Expected and healthy under at-least-once delivery. Not a warning.
            LogDuplicateSuppressed(envelope.EventType, envelope.EventId, _consumerName);
            return InboxOutcome.Skipped;
        }

        try
        {
            var outcome = await handler.HandleAsync(envelope, ct).ConfigureAwait(false);
            await _store.CompleteAsync(envelope.EventId, _consumerName, outcome, ct).ConfigureAwait(false);
            return outcome;
        }
        catch (Exception ex)
        {
            await _store.RecordFailureAsync(envelope.EventId, _consumerName, ex.Message, ct)
                        .ConfigureAwait(false);
            LogHandlerFailed(ex, envelope.EventType, envelope.EventId, _consumerName);

            // Let SQS redrive policy decide when this becomes a dead letter. The
            // service does not second-guess the queue's retry budget.
            return InboxOutcome.RetryLater;
        }
    }

    public static EventEnvelope Deserialize(string body) =>
        JsonSerializer.Deserialize<EventEnvelope>(body)
        ?? throw new JsonException("Message body did not deserialize to an EventEnvelope.");

    [LoggerMessage(Level = LogLevel.Warning,
        Message = "Consumer {Consumer} received {EventType} but has no handler. Check the EventBridge rule.")]
    private partial void LogUnsubscribedEvent(string eventType, string consumer);

    [LoggerMessage(Level = LogLevel.Error,
        Message = "Consumer {Consumer} cannot handle {EventType} v{EventVersion}. Dead-lettered pending consumer upgrade.")]
    private partial void LogUnsupportedVersion(string eventType, int eventVersion, string consumer);

    [LoggerMessage(Level = LogLevel.Debug,
        Message = "Duplicate {EventType} ({EventId}) suppressed for {Consumer}.")]
    private partial void LogDuplicateSuppressed(string eventType, Guid eventId, string consumer);

    [LoggerMessage(Level = LogLevel.Error,
        Message = "Handler for {EventType} ({EventId}) failed in {Consumer}. Returning to queue.")]
    private partial void LogHandlerFailed(Exception exception, string eventType, Guid eventId, string consumer);
}
