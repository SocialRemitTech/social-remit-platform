# Social Remit Platform — Middleware Monorepo

**Baseline:** Developer Baseline 2.0 (Sections 1–3), approved microservices architecture.
**Stack:** C# / .NET 10 LTS · ASP.NET Core · PostgreSQL (Aurora) · Redis · SQS · EventBridge · S3 · KMS/Secrets Manager · ECS Fargate · Terraform · GitHub Actions.

This repository is contract-first. No service code is written before its OpenAPI route and event
schema exist in `/contracts` and pass CI compatibility checks.

---

## 1. Where this fits

The frontend prototype (React Native, 100+ screens, already built) currently holds journey state in
`App.tsx` — navigation stack, `kycStatus`, `promotionStatus`, `savedPin`, routing rules, all client-side.
Baseline 2.0 moves every one of those decisions server-side. The app becomes a renderer of
middleware-returned state and `nextActions`.

That is the single biggest source of tech debt in the current MVP and the first thing this
programme repays.

---

## 2. Build sequence

Each step is independently shippable and testable. Do not start a step until the previous one's
Definition of Done is green in CI.

| Step | Name | Delivers | Blocking inputs |
|---|---|---|---|
| **1** | **Platform foundation** *(this drop)* | Monorepo layout, canonical API envelope, error catalogue, event envelope + schema registry, transactional outbox/inbox, idempotency store, request-context middleware, platform SQL migration, contract CI | None |
| 2 | Infrastructure baseline | Terraform: VPC, ECS cluster, ECR, API Gateway, Aurora, Redis, SQS+DLQ, EventBridge bus, KMS, Secrets Manager, OTel→CloudWatch | AWS account topology |
| 3 | Service template + Mobile BFF | `dotnet new` service template; BFF with `/v1/app/bootstrap`, `/v1/help/entry`, version gating, maintenance mode | Step 1, 2 |
| 4 | Customer & Journey | `registration_journeys`, `customers`, `customer_profiles`, journey state machine, greeting, service-intent | Step 3 |
| 5 | Identity & Access (core) | Phone normalisation (E.164), OTP challenge lifecycle, passcode credential + policy, sessions | Step 3; OTP provider |
| 6 | Consent & Legal | Legal document versions, acceptances w/ evidence, provisional communication preference | Legal doc URLs/versions |
| 7 | Notification | SMS/email/push adapters, retry, delivery status, suppression | Provider selection |
| 8 | Identity ↔ Journey event wiring | `phone.verified.v1` + `passcode.configured.v1` → PROSPECT invariant, reconciliation job | Steps 4–7 |
| 9 | Devices, biometrics, sessions | Device trust model, recognised vs new device, step-up, `/v1/security/authorize-action` | Step 8 |
| 10 | Recovery orchestration | Verified-email recovery, new-phone challenge, assisted-recovery queue | Recovery policy owner |
| 11 | Audit & Reporting | Append-only audit ingestion, privacy-safe analytics events | Step 1 |
| 12 | Provider integration layer | `IPayoutProviderAdapter` + FinCode adapter scaffold; Falcon/BigPay and Velocity behind the same interface | **FinCode docs + sandbox** |
| 13 | Sections 4–10 domains | Quote & Corridor, Recipient, Compliance & Risk, Transfer, Payment, Reconciliation | Sections 4–10 product spec |
| 14 | Campaign 4.1 | Campaign config model, calculation engine, rate snapshot/lock, promotional ledger | Campaign 4.1 middleware spec |

Steps 1–11 have **no external provider dependency**. That matters: FinCode documentation is the
single blocking input in the whole plan, and it blocks nothing until Step 12. Build the whole
identity and journey spine while that conversation runs.

---

## 3. Repository layout

**This repo is backend only.** The React Native app lives in `social-remit-mobile`, a separate
repository, and consumes `/contracts` as a published npm package. See
[ADR 0001 — Repository topology](docs/adr/0001-repository-topology.md) for the reasoning and the
mechanism that keeps the two in step.

```
/social-remit-platform
  SocialRemit.sln               # one solution — developer convenience, not coupling
  Directory.Build.props         # warnings-as-errors, nullable, analyzers, for every project
  Directory.Packages.props      # central NuGet version management
  /contracts                    # source of truth, versioned, CI-enforced, published on merge
    /openapi/mobile-bff.v1.yaml       public mobile contract
    /openapi/internal/*.v1.yaml       service-to-service contracts
    /events/envelope.schema.json      universal event envelope
    /events/*.v1.schema.json          per-event payload schemas
    /events/CATALOGUE.md              producer/consumer ownership
    /errors/error-catalogue.json      stable client-facing codes + copy keys
  /building-blocks              # technical concerns ONLY — never business rules
    SocialRemit.BuildingBlocks.Api
    SocialRemit.BuildingBlocks.Messaging
    SocialRemit.BuildingBlocks.Security
    SocialRemit.BuildingBlocks.Observability
  /services                     # one folder per independently deployable service
    /mobile-bff  /identity-access  /customer-journey  /consent-legal
    /notification  /audit-reporting  /provider-integration
  /db/platform                  # migrations shared by every service (outbox/inbox/idempotency)
  /infrastructure/terraform
  /tests/{contract,integration,end-to-end}
  /docs/adr
  /.github/workflows
```

**Rule (Baseline 2.0 §2.4.7):** no shared library may contain cross-service business rules.
`/building-blocks` holds telemetry, messaging envelopes, security primitives and HTTP plumbing.
If a PR adds a domain concept to `/building-blocks`, reject it.

**Rule (ADR 0001):** a service project may `ProjectReference` only `building-blocks/*` — never
another service. Enforced by the `service-isolation` CI job, not by code review.

---

## 4. What Step 1 gives you

| File | Purpose |
|---|---|
| `contracts/openapi/mobile-bff.v1.yaml` | Every CONFIRMED Section 1–3 public route, with the standard envelope, required headers and error model |
| `contracts/events/envelope.schema.json` | The envelope every domain event must satisfy |
| `contracts/events/CATALOGUE.md` | Event → producer → consumers → payload, versioned |
| `contracts/errors/error-catalogue.json` | Stable codes, copy keys, client treatment. No provider text ever reaches the customer |
| `db/platform/001_building_blocks.sql` | `outbox_events`, `inbox_messages`, `idempotency_records` — applied to **every** service database |
| `building-blocks/...Api/ApiEnvelope.cs` | `{ data, meta, error }` response shape + result helpers |
| `building-blocks/...Api/RequestContext.cs` | Correlation ID, app version, platform, device installation, journey token plumbing |
| `building-blocks/...Api/Idempotency.cs` | `Idempotency-Key` filter: replay-safe state-changing endpoints |
| `building-blocks/...Messaging/EventEnvelope.cs` | Typed envelope + factory that enforces causation/correlation chaining |
| `building-blocks/...Messaging/Outbox.cs` | Transactional outbox writer + relay hosted service (commit-then-publish) |
| `building-blocks/...Messaging/Inbox.cs` | Idempotent consumer with dedupe-by-`eventId` and DLQ classification |
| `.github/workflows/contracts.yml` | Breaking-change detection on OpenAPI + event schemas |

Code here is written against .NET 10 / EF Core / AWS SDK but **has not been compiled in this
environment** (no NuGet egress). Expect to resolve package versions on first `dotnet restore`.

---

## 5. Non-negotiable conventions

1. **Social Remit IDs are canonical.** Provider IDs live only in `provider_mappings` inside the
   provider-integration service. Never in a mobile payload.
2. **Commit, then publish.** Domain events are written to `outbox_events` in the same transaction as
   the state change. A relay publishes them. No service publishes directly from a request handler.
3. **Every state-changing endpoint is idempotent.** `Idempotency-Key` required; the stored response
   is replayed on retry, including the original status code.
4. **Fail closed on security decisions.** If Identity & Access cannot be reached for an
   authorisation decision, the answer is "step-up required", never "allow".
5. **The BFF is not a system of record.** It composes and translates. Any `if` statement in the BFF
   that encodes a business rule belongs in the owning service.
6. **Configuration, not code.** OTP length/expiry/attempts, passcode policy, session TTLs, device
   trust TTL, cooling-off, feature flags, legal document versions — all configuration, all versioned,
   all audited (Baseline 2.0 §33).
7. **No plaintext secrets in logs.** Passcodes, OTP codes, biometric assertions and tokens are
   redacted at the logging sink, not by developer discipline.

---

## 6. Decisions taken in this step (challenge them now, not in month three)

| Decision | Rationale | Reversible? |
|---|---|---|
| Contracts live in-repo, not in a separate registry | One PR changes contract + implementation + consumer test | Yes, cheaply |
| Schema-per-service in one Aurora cluster for MVP | Cost; isolation preserved via separate credentials + prohibition on cross-service SQL | Yes — schema → database is a connection-string change |
| EventBridge for domain events, SQS for work queues | EventBridge gives fan-out + archive/replay; SQS gives ordered retry + DLQ | Yes |
| Outbox relay as an in-process `BackgroundService` | Simplest thing that is correct; no extra deployable | Yes — swap to a dedicated relay task |
| Idempotency records in Postgres, not Redis | Must survive Redis eviction for payment-adjacent flows | Yes |
| `Idempotency-Key` scoped to (key, route, customer) | Prevents key reuse across endpoints masking a different write | No — scope change is breaking |

---

## 7. Open blockers carried forward (owners needed)

These are from Baseline 2.0 §36 and remain unresolved. None block Steps 1–11.

- **FinCode API docs, sandbox, idempotency behaviour, webhook signing** — Engineering/FinCode. Blocks Step 12.
- **KDF/KMS parameters, attempt thresholds, cooldown progression** — Security. Blocks Step 5 go-live, not build.
- **Marketing lawful basis** — Legal/Compliance. Pre-go-live release blocker.
- **Legal document versions and URLs** — Legal. Blocks Step 6 go-live.
- **Assisted-recovery policy, tooling, SLA** — Fraud/Compliance/Ops. Blocks Step 10 go-live.
- **OTP + notification providers** — Engineering. Blocks Steps 5, 7.
- **SLOs, RTO/RPO, retention schedules** — Engineering/Security/Compliance.
- **Payout partner direction-of-flow confirmation (Velocity `Payout` vs `Remittance`)** — Blocks Step 13.
