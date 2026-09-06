using System.Text.Json;
using System.Text.Json.Serialization;

namespace SocialRemit.BuildingBlocks.Messaging;

/// <summary>
/// The envelope every Social Remit domain event travels in.
/// Mirrors contracts/events/envelope.schema.json — the schema is the source of truth,
/// this type is the C# projection of it. CI asserts they agree.
/// </summary>
public sealed record EventEnvelope
{
    [JsonPropertyName("eventId")]        public required Guid EventId { get; init; }
    [JsonPropertyName("eventType")]      public required string EventType { get; init; }
    [JsonPropertyName("eventVersion")]   public required int EventVersion { get; init; }
    [JsonPropertyName("occurredAt")]     public required DateTimeOffset OccurredAt { get; init; }
    [JsonPropertyName("producer")]       public required string Producer { get; init; }
    [JsonPropertyName("correlationId")]  public required Guid CorrelationId { get; init; }
    [JsonPropertyName("causationId")]    public Guid? CausationId { get; init; }
    [JsonPropertyName("subjectId")]      public required string SubjectId { get; init; }
    [JsonPropertyName("traceparent")]    public string? Traceparent { get; init; }
    [JsonPropertyName("payload")]        public required JsonElement Payload { get; init; }
}

/// <summary>
/// Marker for a domain event payload. Implementations are plain records living in the
/// owning service — never in building-blocks, which must stay free of domain concepts.
/// </summary>
public interface IDomainEvent
{
    /// <summary>aggregate.fact, e.g. "phone.verified".</summary>
    static abstract string EventType { get; }

    /// <summary>Bumped only for breaking payload changes.</summary>
    static abstract int EventVersion { get; }

    /// <summary>Canonical Social Remit ID this event is about. Never a provider ID.</summary>
    string SubjectId { get; }
}

/// <summary>
/// Ambient facts about the request or message currently being handled.
/// Populated by RequestContextMiddleware on the HTTP path and by the inbox
/// consumer on the messaging path, so causation chains survive both.
/// </summary>
public interface IAmbientContext
{
    Guid CorrelationId { get; }
    Guid? CausationId { get; }
    string? Traceparent { get; }
}

public static class EventEnvelopeFactory
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    /// <summary>
    /// Wraps a domain event. The caller does not choose the correlation or causation IDs —
    /// they come from ambient context. This is deliberate: a hand-supplied correlation ID is
    /// how traces get silently broken, and a broken trace on a payments platform is a
    /// compliance problem, not just an inconvenience.
    /// </summary>
    public static EventEnvelope Wrap<TEvent>(
        TEvent domainEvent,
        string producer,
        IAmbientContext context,
        TimeProvider? timeProvider = null)
        where TEvent : IDomainEvent
    {
        ArgumentNullException.ThrowIfNull(domainEvent);
        ArgumentException.ThrowIfNullOrWhiteSpace(producer);
        ArgumentNullException.ThrowIfNull(context);

        var subjectId = domainEvent.SubjectId;
        if (string.IsNullOrWhiteSpace(subjectId))
        {
            throw new InvalidOperationException(
                $"{TEvent.EventType} produced an empty SubjectId. Every event must name the canonical entity it concerns.");
        }

        var payload = JsonSerializer.SerializeToElement(domainEvent, SerializerOptions);
        RedactionGuard.AssertNoForbiddenKeys(payload, TEvent.EventType);

        var clock = timeProvider ?? TimeProvider.System;

        return new EventEnvelope
        {
            EventId       = Guid.CreateVersion7(),
            EventType     = TEvent.EventType,
            EventVersion  = TEvent.EventVersion,
            OccurredAt    = clock.GetUtcNow(),
            Producer      = producer,
            CorrelationId = context.CorrelationId,
            CausationId   = context.CausationId,
            SubjectId     = subjectId,
            Traceparent   = context.Traceparent,
            Payload       = payload
        };
    }
}

/// <summary>
/// Runtime backstop for the CI redaction lint. Schema linting catches declared properties;
/// this catches anything a serializer added at runtime. Two layers, because a passcode
/// leaking into an event archive is not something you fix after the fact.
/// </summary>
internal static class RedactionGuard
{
    private static readonly HashSet<string> Forbidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "passcode", "passcodeConfirmation", "otp", "code", "accessToken", "refreshToken",
        "biometricTemplate", "phoneNumber", "email", "legalName", "providerErrorMessage"
    };

    public static void AssertNoForbiddenKeys(JsonElement element, string eventType, int depth = 0)
    {
        if (depth > 12) return;

        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    if (Forbidden.Contains(property.Name))
                    {
                        throw new InvalidOperationException(
                            $"Event '{eventType}' payload contains forbidden field '{property.Name}'. " +
                            "Publish a reference or hash instead. See contracts/events/envelope.schema.json.");
                    }
                    AssertNoForbiddenKeys(property.Value, eventType, depth + 1);
                }
                break;

            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    AssertNoForbiddenKeys(item, eventType, depth + 1);
                }
                break;
        }
    }
}
