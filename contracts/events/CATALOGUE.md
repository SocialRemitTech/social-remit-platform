# Event catalogue — Sections 1–3

Every event conforms to `envelope.schema.json`. One service owns each event; consumers are listed
explicitly. Adding a consumer is a PR against this file — an undeclared consumer is a CI failure.

**Naming:** `aggregate.fact` in the envelope's `eventType`, with `eventVersion` carried separately.
The `.v1` suffix used in prose below refers to `eventType` + `eventVersion: 1`.

**Delivery:** EventBridge bus `social-remit-domain`, one SQS queue + DLQ per (event, consumer) pair.
At-least-once. Consumers are idempotent by `eventId` via `inbox_messages`.

---

## Section 1 — entry and product access

| Event | Producer | Consumers | Payload (privacy-minimised) |
|---|---|---|---|
| `registration.started` | customer-journey | audit-reporting | `journeyId`, `appVersion`, `platform`, `deviceInstallationIdHash` |
| `prospect.created` | customer-journey | audit-reporting; provider-integration *(only if provider creation is later configured)* | `customerId`, `journeyId`, `createdAt` |
| `greeting.preference_saved` | customer-journey | audit-reporting | `customerId`, `hasPreferredName` (bool), `hasPreferredGreeting` (bool) — **never the text** |
| `service_intent.selected` | customer-journey | audit-reporting | `customerId`, `intent` |
| `help.opened` | mobile-bff | audit-reporting | `journeyState`, `entryPoint` |

## Section 2 — account creation

| Event | Producer | Consumers | Payload |
|---|---|---|---|
| `phone.challenge_issued` | identity-access | notification; audit-reporting | `challengeId`, `purpose`, `destinationRef` (tokenised), `expiresAt`, `attemptsAllowed` |
| `phone.verified` | identity-access | customer-journey; audit-reporting | `customerId` or `journeyId`, `challengeId`, `verifiedAt` |
| `phone.challenge_failed` | identity-access | audit-reporting | `challengeId`, `reason` (`INCORRECT`\|`EXPIRED`\|`SUPERSEDED`\|`ATTEMPTS_EXHAUSTED`), `attemptsRemaining` |
| `legal.account_accepted` | consent-legal | audit-reporting | `customerId`, `documents[]` (`type`, `version`, `action`), `acceptedAt`, `evidenceRef` |
| `communication.preference_changed` | consent-legal | notification; audit-reporting | `preferenceId`, `customerId`, `purpose`, `channels[]`, `selection`, `legalStatus` |
| `profile.email_captured` | customer-journey | audit-reporting | `customerId`, `emailRef` (hashed), `capturedAt` |
| `profile.email_verified` | identity-access | customer-journey; audit-reporting | `customerId`, `verifiedAt` |

## Section 3 — authentication and security

| Event | Producer | Consumers | Payload |
|---|---|---|---|
| `passcode.configured` | identity-access | customer-journey; audit-reporting | `customerId`, `credentialId`, `configuredAt` |
| `authentication.succeeded` | identity-access | audit-reporting | `customerId`, `sessionId`, `methodsUsed[]`, `deviceId`, `assuranceLevel` |
| `authentication.failed` | identity-access | audit-reporting | `subjectRef`, `factor`, `reasonCode`, `attemptsRemaining` |
| `device.registered` | identity-access | notification; audit-reporting | `customerId`, `deviceId`, `platform`, `registeredAt` |
| `device.revoked` | identity-access | notification; audit-reporting | `customerId`, `deviceId`, `reason` |
| `biometrics.preference_changed` | identity-access | audit-reporting | `customerId`, `deviceId`, `enabled` |
| `recovery.started` | identity-access | audit-reporting | `recoveryId`, `route`, `startedAt` |
| `recovery.completed` | identity-access | notification; audit-reporting | `recoveryId`, `customerId`, `outcome`, `factorsUsed[]` |
| `registered_phone.changed` | identity-access | customer-journey; notification; audit-reporting; provider-integration *(when a mapping exists)* | `customerId`, `changedAt`, `previousDestinationRef`, `newDestinationRef` |
| `passcode.reset` | identity-access | notification; audit-reporting | `customerId`, `resetAt`, `sessionsRevoked` (int) |

---

## The PROSPECT invariant (Baseline 2.0 §32.1)

`prospect.created` is **derived**, not commanded. Customer & Journey consumes two authoritative
events and only transitions when both are present:

```
is_prospect = phone_verified_at IS NOT NULL AND passcode_credential_status = ACTIVE
```

1. identity-access commits `phone_verified` + outbox row in one transaction.
2. identity-access commits `passcode.configured` + outbox row in one transaction.
3. customer-journey consumes both idempotently, in any order, possibly duplicated.
4. When both conditions hold, it transitions to `PROSPECT` and publishes `prospect.created`.
5. If customer-journey is down, the events stay durable. The BFF returns a
   `SETUP_COMPLETING` state and the client polls `GET /v1/journeys/{id}` — it **must not**
   re-submit the passcode.
6. A nightly reconciliation job finds customers where both source facts exist but the transition
   never happened, and replays.

No distributed transaction. No synchronous call from identity-access to customer-journey on the
write path.

---

## Versioning rules

| Change | Allowed in-place? | Action |
|---|---|---|
| Add an optional payload field | Yes | Same `eventVersion` |
| Add an enum value a consumer must handle | No | New `eventVersion` |
| Remove or rename a field | No | New `eventVersion`; dual-publish until all consumers migrate |
| Tighten a type or constraint | No | New `eventVersion` |
| Change `subjectId` meaning | No | New event type entirely |

Dual-publish window: producer emits vN and vN+1 until every declared consumer reports vN+1 in its
contract test. Only then is vN retired, and its retirement is a separate PR.

---

## Redaction lint

CI rejects any payload schema that declares a property in `envelope.schema.json#/$defs/forbiddenPayloadKeys`.
This is the mechanical enforcement of "no secrets, no OTPs, no passcodes, no provider error text in
events" — it is not left to code review.
