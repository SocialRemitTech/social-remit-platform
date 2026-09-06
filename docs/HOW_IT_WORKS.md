# How it works — the three patterns, in plain language

Every file in `building-blocks/` exists to solve one of three problems. If you understand these
three, the rest of the codebase reads easily. If you skip them, the code will look like
over-engineering.

All three come from the same root cause: **things fail halfway through.** A phone loses signal
between sending a request and getting the answer. A server is restarted mid-operation. A network
message is delivered twice. On a chat app, none of that matters much. On a platform that moves
someone's rent money to their mother, all of it matters.

---

## Problem 1 — the customer taps the button twice

### What goes wrong

A customer taps "Send code". The phone sends the request. The network stalls. The customer sees
nothing happen and taps again.

The server has now received two identical requests. Without protection it issues two OTP codes.
The second code invalidates the first — so the customer receives two texts, types the first one
they see, and it does not work. They have done nothing wrong and the app looks broken.

Later in the programme, the same failure on "Confirm transfer" takes the money twice.

### The fix: idempotency

The app generates a random key for each *intent* and sends it in the `Idempotency-Key` header. Not
per request — per intent. Both taps of the same button carry the same key.

The server keeps a record of every key it has seen:

- **Key never seen before** → do the work, save the response, return it.
- **Key seen, work finished** → do not do the work again. Return the saved response, byte for byte.
- **Key seen, work still running** → return "in progress, try again in 2 seconds".
- **Key seen, but the request body is different** → reject. The client has a bug: it reused a key
  for a different intent, and replaying the wrong answer would be worse than an error.

The customer's second tap gets the same answer as the first. One OTP. One transfer.

### Where it lives

- `building-blocks/SocialRemit.BuildingBlocks.Api/Idempotency.cs`
- `db/platform/001_building_blocks.sql` → `idempotency_records`

### The detail that matters

The record lives in PostgreSQL, not Redis. Redis evicts data when it runs out of memory. If the
idempotency record for a payment is evicted, the retry executes the payment a second time. A cache
that "usually" remembers is not good enough for money.

---

## Problem 2 — the state was saved but nobody was told

### What goes wrong

Two things must happen when a customer verifies their phone:

1. Identity & Access saves "this phone is verified".
2. Customer & Journey is told, so it can move the customer forward.

They are separate services with separate databases, so there is no single transaction covering
both. The obvious approach — save, then send a message — has a gap:

```
save to database        ✓ succeeded
                        ← server crashes here
send the message        ✗ never happened
```

The phone is verified forever, and nothing downstream ever hears about it. The customer is stuck
on a screen that will never advance, and no error was logged, because nothing errored.

Reversing the order is worse: you announce a fact, then fail to save it, and now downstream
services believe something that is not true.

### The fix: the transactional outbox

Do not send the message. **Write it into the same database, in the same transaction as the state
change.**

```
BEGIN
  UPDATE contacts SET phone_verified_at = now()      -- the state change
  INSERT INTO outbox_events (...)                    -- the announcement
COMMIT
```

Both succeed or neither does. There is no gap.

A separate background loop — the **relay** — reads committed rows from `outbox_events` and
publishes them. If publishing fails, the row stays there and is retried with increasing delays. If
the whole service dies, the rows are still in the database when it comes back.

The event cannot be lost, because it is stored in the same place as the fact it describes.

### Where it lives

- `building-blocks/SocialRemit.BuildingBlocks.Messaging/Outbox.cs`
- `db/platform/001_building_blocks.sql` → `outbox_events`

### The detail that matters

An event that fails every retry is **never deleted**. It is marked `FAILED` and raises an alarm.
It describes something that genuinely happened, and quietly discarding it would leave the system
permanently inconsistent with no trace of why.

---

## Problem 3 — the same message arrives twice

### What goes wrong

The outbox guarantees an event is delivered *at least* once. It cannot guarantee *exactly* once —
nothing can, across a network. The relay might publish successfully and then crash before marking
the row done. On restart it publishes again.

So consumers see duplicates. If a consumer naively acts every time, one "phone verified" event
becomes two, and any counter, credit or notification driven by it fires twice.

### The fix: the inbox

Before acting, the consumer records the event's unique ID. The ID is the table's primary key, so
the second attempt to insert it fails — and that failure *is* the duplicate signal.

```
first delivery   → insert succeeds → do the work
second delivery  → insert fails    → skip, acknowledge, move on
```

Critically, the ID is recorded **in the same transaction as the work**. Recording it afterwards
leaves a gap where the work is done and the evidence is not — and a redelivery in that gap does
the work twice, which is the exact bug we set out to prevent.

### Where it lives

- `building-blocks/SocialRemit.BuildingBlocks.Messaging/Inbox.cs`
- `db/platform/001_building_blocks.sql` → `inbox_messages`

### The detail that matters

Events can also arrive **out of order**. "Passcode created" may arrive before "phone verified"
even though the customer did them the other way round. Consumers must not assume order. See the
PROSPECT example below for how we handle that.

---

## Putting it together: how a customer becomes a Prospect

A customer is a **Prospect** — allowed to see exchange rates and start building a transfer — only
when both of these are true:

```
phone verified   AND   passcode created
```

Two different facts, owned by one service (Identity & Access), consumed by another
(Customer & Journey). Here is the whole flow.

```
Customer confirms OTP
  └─ Identity & Access:  BEGIN
                           mark phone verified
                           write "phone.verified" to outbox
                         COMMIT
  └─ relay publishes it

Customer creates passcode
  └─ Identity & Access:  BEGIN
                           store passcode verifier
                           write "passcode.configured" to outbox
                         COMMIT
  └─ relay publishes it

Customer & Journey receives both events (in any order, possibly twice)
  └─ inbox rejects duplicates
  └─ when BOTH facts are present → customer becomes PROSPECT
  └─ writes "prospect.created" to its own outbox
```

Notice what is **not** here: no service calls another service and waits. Identity & Access finishes
its work and commits. If Customer & Journey is down for ten minutes, the events sit durably in the
outbox and are delivered when it recovers.

### What the customer sees during that gap

The app asks "what state am I in?" and gets back `SETUP_COMPLETING`, meaning *your work is saved,
we are catching up.* The app polls. It does **not** re-submit the passcode — resubmitting a
credential because a downstream projection is lagging is how duplicate accounts get created.

### The safety net

A nightly reconciliation job looks for customers where both facts exist but the transition never
happened, and replays. Retries handle transient failures; reconciliation handles the failures
retries missed. You need both.

---

## Why this is not over-engineering

A reasonable reaction is: this is a lot of machinery for a signup flow.

Two answers.

**One.** These are not signup patterns, they are money-movement patterns. The same outbox that
carries "phone verified" today carries "transfer submitted to payout partner" in Step 13. You
cannot retrofit them then — by that point there are twenty services, each with its own accidental
approach, and unifying them is a rewrite. The cost of building them now is a week. The cost of
building them later is a quarter.

**Two.** Once they exist in `building-blocks`, a service author does not think about them. They
write `await _outbox.EnqueueAsync(new PhoneVerified(...), transaction)` and correctness is
inherited. The complexity is paid once, centrally, by the people best placed to get it right.

---

## Where to look next

| Question | File |
|---|---|
| What exactly can the mobile app call? | `contracts/openapi/mobile-bff.v1.yaml` |
| What events exist and who listens? | `contracts/events/CATALOGUE.md` |
| What errors can a customer see? | `contracts/errors/error-catalogue.json` |
| What do these words mean? | `docs/GLOSSARY.md` |
| Why two repositories? | `docs/adr/0001-repository-topology.md` |
| What is being built, in what order? | `README.md` §2 |
