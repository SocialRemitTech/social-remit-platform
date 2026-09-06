# Glossary

Every term used in this repository, defined. Grouped by area. If you hit a word in a code comment
or a spec that is not here, add it.

---

## Social Remit domain

| Term | Meaning |
|---|---|
| **Corridor** | A send route: origin country + destination country + delivery channel. "UK → Ghana, mobile wallet" is one corridor; "UK → Ghana, bank deposit" is a different one, because it has a different partner, fee and failure mode. |
| **MTO** | Money Transfer Operator. The partner that actually pays the recipient in the destination country. BigPay in Ghana, Velocity in Nigeria, M-Pesa in Kenya. |
| **FinCode** | An external provider Social Remit integrates with. Sits behind an adapter. Its identifiers, statuses and errors never reach the mobile app. |
| **Payout leg** | The final delivery of funds to the recipient, executed by the MTO. |
| **Prospect** | A customer who has verified their phone and created a passcode. May check rates and start building a transfer. May **not** complete a regulated transaction until further gates pass. |
| **Established recipient** | A recipient who has received at least one **confirmed delivered** transfer. Creating, paying for or submitting a transfer does not establish them. Changing their payout details un-establishes them. |
| **Coverage limit** | In a rate promotion, the amount of a transfer that gets the promotional rate. Above it, the standard rate applies. |
| **Rate snapshot** | The exchange rate captured at a moment and held for a customer, so the number they were shown is the number they get. |

---

## Compliance

| Term | Meaning |
|---|---|
| **KYC** | Know Your Customer. Verifying a customer is who they claim to be. Legally required before moving money. |
| **EDD** | Enhanced Due Diligence. Deeper checks triggered by higher risk — large amounts, certain corridors, unusual patterns. Asks for source of funds and source of wealth. |
| **AML** | Anti-Money Laundering. Controls preventing the platform being used to launder money. |
| **Sanctions screening** | Checking names against government lists of people and entities who must not be paid. Runs on every transaction. |
| **PEP** | Politically Exposed Person. Higher-risk category requiring extra scrutiny. |
| **BVN** | Bank Verification Number. Nigeria's national banking identifier. |
| **Data residency** | Rules requiring certain customer data to be physically stored inside a particular country. |
| **Safeguarding** | The legal requirement to hold customer funds separately from company funds. |

---

## Architecture

| Term | Meaning |
|---|---|
| **Middleware** | Everything between the mobile app and external providers. In this repo, "middleware" and "backend" mean the same thing. |
| **Microservice** | An independently deployable application owning one business area and its own database. |
| **BFF** | Backend For Frontend. One service that the mobile app talks to; it composes responses from other services. The app never calls a domain service directly. |
| **Domain service** | A service owning one business area — Identity & Access, Customer & Journey. Only the BFF and other services call it. |
| **Canonical ID** | A Social Remit identifier (`cus_...`, `jrny_...`) that is the real, primary identifier. Provider IDs map to it and are never primary. |
| **Provider mapping** | A row linking a Social Remit ID to a provider's ID for the same thing. Lives only in the provider-integration service. |
| **Adapter** | Code translating between Social Remit's language and one provider's API. Swapping providers should change only the adapter. |
| **Aggregate** | A cluster of data changed together and owned by exactly one service. "Customer" is an aggregate. |
| **Modular monolith** | One deployable application with clean internal module boundaries. Recommended in the original spec; superseded by microservices in Baseline 2.0. |

---

## Messaging and reliability

| Term | Meaning |
|---|---|
| **Event** | A record that something happened, published for other services. Past tense: `phone.verified`, not `verify.phone`. |
| **Envelope** | The standard wrapper around every event: who produced it, when, what it concerns, which interaction it belongs to. |
| **Outbox** | Table where a service writes an event in the same transaction as the state change, so the event cannot be lost. See `docs/HOW_IT_WORKS.md`. |
| **Inbox** | Table where a consumer records event IDs it has handled, so duplicate deliveries are ignored. |
| **Idempotent** | Doing it twice has the same effect as doing it once. |
| **Idempotency key** | Header identifying a customer *intent*, so retries are recognised as retries. |
| **At-least-once delivery** | The delivery guarantee we have: a message arrives, possibly more than once, possibly out of order. Consumers must cope. |
| **DLQ** | Dead Letter Queue. Where messages go after repeated failure, so a poison message does not block the queue. Always alarmed. |
| **Correlation ID** | One ID attached to everything a single customer interaction touches, across all services. The first thing you ask for in an incident. |
| **Causation ID** | The specific event or request that directly caused this one. Correlation says "same interaction"; causation says "this happened because of that". |
| **Circuit breaker** | Stops calling a failing dependency for a while, rather than piling up timeouts. |
| **Compensating action** | An undo. Used instead of distributed transactions, which we do not use. |
| **Reconciliation** | A scheduled job comparing two systems and fixing drift. The safety net beneath retries. |

---

## Security and identity

| Term | Meaning |
|---|---|
| **Passcode** | The five-digit code Social Remit uses instead of a password. Stored only as a one-way verifier, never readable. |
| **Verifier** | The stored one-way transformation of a passcode. It can confirm a guess is correct but cannot reveal the passcode. |
| **KDF** | Key Derivation Function. The deliberately slow algorithm (Argon2id) that produces the verifier, making brute force impractical. |
| **Pepper** | A secret added before hashing, stored separately from the database. Someone who steals the database alone still cannot attack the hashes. |
| **OTP** | One-Time Passcode. The six-digit code sent by SMS. |
| **Step-up** | Asking for extra proof before a sensitive action, even though the customer is already signed in. |
| **Assurance level** | How confident we are in the current identity proof. Determines which actions are permitted. |
| **Device trust** | Whether we recognise this phone. A recognised device needs fewer factors than a new one. |
| **Attestation** | A cryptographic statement from iOS or Android that the app is genuine and unmodified. |
| **Fail closed** | On failure, deny. If we cannot check whether an action is allowed, the answer is no. The opposite, fail open, is how systems get exploited during outages. |
| **Enumeration** | An attack that discovers which phone numbers have accounts by comparing responses. Defended by making responses identical either way. |
| **E.164** | The international phone number standard: `+447700900123`. Everything is normalised to it before storage or comparison. |

---

## Delivery and tooling

| Term | Meaning |
|---|---|
| **Monorepo** | One repository holding several projects. This repo holds all backend services. The mobile app is separate — see ADR 0001. |
| **ADR** | Architecture Decision Record. A short document capturing a decision, the alternatives, and the reasoning, so future readers do not have to guess. |
| **OpenAPI** | The standard format for describing an HTTP API. `contracts/openapi/mobile-bff.v1.yaml` is ours. |
| **Contract-first** | Agreeing the API shape before writing code. Prevents the client and server discovering a disagreement in QA. |
| **Consumer-driven contract test** | A test written from the *caller's* perspective, run against the provider, that fails if the provider breaks the caller. |
| **Breaking change** | A change that stops an existing caller working. On a mobile API this is severe: installed apps cannot be forced to update. |
| **Testcontainers** | Library that starts a real PostgreSQL in Docker for a test, then throws it away. Lets us test real database behaviour instead of a fake. |
| **LocalStack** | A fake AWS that runs on your laptop. Develop against SQS and EventBridge with no AWS account. |
| **Terraform** | Describes cloud infrastructure as code, so environments are reproducible and reviewable. |
| **ECS Fargate** | AWS service that runs containers without you managing servers. |
| **IaC** | Infrastructure as Code. |
| **Feature flag** | A configuration switch turning behaviour on or off without deploying. |

---

## Status labels in the specification

From Baseline 2.0 §1. These appear throughout the source documents.

| Label | What to do |
|---|---|
| **CONFIRMED** | Decided. Implement and test it. |
| **PROVISIONAL — PHASE 1** | Needed now, may change. Implement through configuration; never hard-code. |
| **PLACEHOLDER** | Value or policy not yet supplied. Create the interface or config key. **Do not invent a production value.** |
| **PRE-GO-LIVE DECISION** | Build it, but production release is blocked until someone named approves. Belongs on the release checklist. |
| **POST-MVP** | Excluded for now. Leave room for it; do not build it. |
