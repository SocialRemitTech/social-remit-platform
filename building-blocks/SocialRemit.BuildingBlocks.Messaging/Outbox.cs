using System.Data;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SocialRemit.BuildingBlocks.Messaging;

// ============================================================================
// Transactional outbox
//
// The rule (Baseline 2.0 §2.4.3): a service publishes an event only after its
// local state is committed. We achieve that by writing the event into the same
// transaction as the state change, then relaying committed rows asynchronously.
//
// The alternative — publish inside the handler — produces two failure modes we
// cannot tolerate on a payments platform: an event for a state change that was
// rolled back, and a committed state change whose event never arrived. Either
// one silently breaks the PROSPECT invariant.
// ============================================================================

public sealed record OutboxRow
{
    public long Id { get; init; }
    public required Guid EventId { get; init; }
    public required string EventType { get; init; }
    public required int EventVersion { get; init; }
    public required string SubjectId { get; init; }
    public required Guid CorrelationId { get; init; }
    public Guid? CausationId { get; init; }
    public string? Traceparent { get; init; }
    public required string PayloadJson { get; init; }
    public required DateTimeOffset OccurredAt { get; init; }
    public int Attempts { get; init; }
}

/// <summary>
/// Enqueues a domain event onto the outbox. MUST be called inside the caller's
/// open transaction — the implementation participates in it rather than opening
/// its own connection.
/// </summary>
public interface IOutboxWriter
{
    Task EnqueueAsync<TEvent>(TEvent domainEvent, IDbTransaction transaction, CancellationToken ct = default)
        where TEvent : IDomainEvent;
}

/// <summary>Store operations the relay needs. Implemented per service over its own database.</summary>
public interface IOutboxStore
{
    /// <summary>
    /// Claims a batch using FOR UPDATE SKIP LOCKED so several ECS tasks can relay
    /// concurrently without a leader election or a distributed lock.
    /// </summary>
    Task<IReadOnlyList<OutboxRow>> ClaimDueBatchAsync(int batchSize, CancellationToken ct);

    Task MarkPublishedAsync(IReadOnlyCollection<long> ids, CancellationToken ct);

    Task MarkFailedAsync(long id, string error, DateTimeOffset nextAttemptAt, CancellationToken ct);
}

/// <summary>Transport. EventBridge in production; an in-memory fake in tests.</summary>
public interface IEventTransport
{
    Task PublishAsync(IReadOnlyCollection<EventEnvelope> envelopes, CancellationToken ct);
}

public sealed class OutboxRelayOptions
{
    public string Producer { get; set; } = string.Empty;
    public int BatchSize { get; set; } = 100;
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// After this many attempts the row is left FAILED and alarms. It is never deleted:
    /// the event describes a fact that already happened, and dropping it is data loss.
    /// </summary>
    public int MaxAttempts { get; set; } = 12;

    public TimeSpan BaseBackoff { get; set; } = TimeSpan.FromSeconds(2);
    public TimeSpan MaxBackoff { get; set; } = TimeSpan.FromMinutes(5);
}

public sealed partial class OutboxRelay : BackgroundService
{
    private readonly IOutboxStore _store;
    private readonly IEventTransport _transport;
    private readonly OutboxRelayOptions _options;
    private readonly TimeProvider _time;
    private readonly ILogger<OutboxRelay> _logger;

    public OutboxRelay(
        IOutboxStore store,
        IEventTransport transport,
        IOptions<OutboxRelayOptions> options,
        TimeProvider time,
        ILogger<OutboxRelay> logger)
    {
        _store = store;
        _transport = transport;
        _options = options.Value;
        _time = time;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var published = 0;
            try
            {
                published = await RelayOnceAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // The relay must not die. A poisoned batch is handled per-row below;
                // anything reaching here is infrastructural and resolves on the next tick.
                LogRelayCycleFailed(ex);
            }

            // Drain greedily: if the batch was full there is probably more waiting.
            if (published < _options.BatchSize)
            {
                await Task.Delay(_options.PollInterval, _time, stoppingToken).ConfigureAwait(false);
            }
        }
    }

    private async Task<int> RelayOnceAsync(CancellationToken ct)
    {
        var batch = await _store.ClaimDueBatchAsync(_options.BatchSize, ct).ConfigureAwait(false);
        if (batch.Count == 0) return 0;

        var envelopes = new List<EventEnvelope>(batch.Count);
        var idsByEventId = new Dictionary<Guid, long>(batch.Count);

        foreach (var row in batch)
        {
            envelopes.Add(new EventEnvelope
            {
                EventId       = row.EventId,
                EventType     = row.EventType,
                EventVersion  = row.EventVersion,
                OccurredAt    = row.OccurredAt,
                Producer      = _options.Producer,
                CorrelationId = row.CorrelationId,
                CausationId   = row.CausationId,
                SubjectId     = row.SubjectId,
                Traceparent   = row.Traceparent,
                Payload       = JsonDocument.Parse(row.PayloadJson).RootElement.Clone()
            });
            idsByEventId[row.EventId] = row.Id;
        }

        try
        {
            await _transport.PublishAsync(envelopes, ct).ConfigureAwait(false);
            await _store.MarkPublishedAsync(idsByEventId.Values.ToArray(), ct).ConfigureAwait(false);
            return batch.Count;
        }
        catch (Exception ex)
        {
            // Publish is at-least-once. If the transport partially succeeded we will
            // republish the whole batch; consumers deduplicate on eventId, which is
            // stable across retries precisely so this is safe.
            foreach (var row in batch)
            {
                var attempts = row.Attempts + 1;
                var nextAttemptAt = _time.GetUtcNow() + ComputeBackoff(attempts);

                if (attempts >= _options.MaxAttempts)
                {
                    LogOutboxExhausted(row.EventType, row.EventId, attempts);
                }

                await _store.MarkFailedAsync(row.Id, Truncate(ex.Message), nextAttemptAt, ct)
                            .ConfigureAwait(false);
            }
            return 0;
        }
    }

    private TimeSpan ComputeBackoff(int attempts)
    {
        // Exponential with full jitter. Without jitter, a transport outage produces a
        // synchronised retry stampede from every ECS task the moment it recovers.
        var exponential = Math.Min(
            _options.MaxBackoff.TotalMilliseconds,
            _options.BaseBackoff.TotalMilliseconds * Math.Pow(2, Math.Min(attempts, 16)));

        return TimeSpan.FromMilliseconds(Random.Shared.NextDouble() * exponential);
    }

    private static string Truncate(string value) =>
        value.Length <= 1000 ? value : value[..1000];

    [LoggerMessage(Level = LogLevel.Error, Message = "Outbox relay cycle failed.")]
    private partial void LogRelayCycleFailed(Exception exception);

    [LoggerMessage(Level = LogLevel.Critical,
        Message = "Outbox event {EventType} ({EventId}) exhausted after {Attempts} attempts and requires operator action. It has NOT been discarded.")]
    private partial void LogOutboxExhausted(string eventType, Guid eventId, int attempts);
}
