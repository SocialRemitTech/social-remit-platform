# Contributing

How to make a change here without breaking the mobile app or leaking something you should not.

---

## The one rule

**Contracts change first.** Not code, then contract. Contract, then code.

If your change touches what the mobile app sends or receives, you edit
`contracts/openapi/mobile-bff.v1.yaml` in the same PR — or in an earlier one. Never after.

The reason: the app is in an app store. Once a version ships, users hold it for weeks and you
cannot force an update. A backend change that breaks an installed app is not a bug you roll back
in five minutes; it is customers unable to send money until they happen to update. The contract is
what stops that, and it only works if it leads.

---

## Making a change

### 1. Branch

```bash
git checkout -b feat/otp-resend-cooldown
```

Prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`.

### 2. Decide what kind of change it is

| Your change | Do this |
|---|---|
| New or altered endpoint | Edit the OpenAPI file first. Then implement. |
| New event | Add it to `contracts/events/CATALOGUE.md` with producer **and** consumers named. Add its payload schema. |
| New customer-visible error | Add it to `contracts/errors/error-catalogue.json` **and** `ErrorCodes.cs`. CI fails if only one changes. |
| New shared plumbing | Goes in `building-blocks/`. If it contains a business rule, it does not belong there. |
| Business logic | Goes in the owning service under `services/`. Never in `building-blocks/`, never in the BFF. |
| Threshold, timeout, limit, policy value | Configuration, not a constant. Baseline 2.0 §33. |

### 3. Write the code

Read `docs/HOW_IT_WORKS.md` first if you have not. Then:

- Publishing an event? Use the outbox. Never publish from a request handler.
- Consuming an event? Assume it will arrive twice and out of order.
- Adding a state-changing endpoint? It requires `Idempotency-Key`. No exceptions.
- Adding a security decision? Fail closed. If you cannot determine the answer, deny.
- Adding a log line? No passcodes, OTPs, tokens, full phone numbers or full email addresses.

### 4. Verify locally

```bash
bash scripts/verify.sh
```

Run this before you push. It is the same set of checks CI runs, and it takes seconds. Pushing and
waiting for CI to tell you a YAML file has a typo wastes ten minutes each time.

### 5. Open the PR

Fill in the checklist below. Reviewers check it.

---

## PR checklist

Copy this into the PR description.

```markdown
### What and why
<!-- One paragraph. What changes, and what problem it solves. -->

### Contract impact
- [ ] No contract change, OR
- [ ] OpenAPI updated and `redocly diff` reports no breaking change, OR
- [ ] Breaking change — version bumped, ADR linked, `contract-breaking-approved` label applied

### Correctness
- [ ] State-changing endpoints require `Idempotency-Key`
- [ ] Events are published via the outbox, inside the state-change transaction
- [ ] Event consumers are idempotent and tolerate out-of-order delivery
- [ ] Security decisions fail closed

### Data protection
- [ ] No passcode, OTP, token, biometric data, full phone number or full email in any log,
      event payload, error response or analytics field
- [ ] No provider (FinCode/MTO/AWS) identifier, status or error text reaches the mobile contract

### Boundaries
- [ ] No service references another service's project or database
- [ ] No business rule added to `building-blocks/`
- [ ] The BFF composes and translates only; it holds no domain logic

### Configuration
- [ ] Thresholds, TTLs, limits and policies are configuration, not constants
- [ ] Any PLACEHOLDER has a config key or backlog ticket — no invented production value

### Tests
- [ ] Unit tests for the rule
- [ ] Integration test against real PostgreSQL via Testcontainers, if persistence changed
- [ ] Duplicate-request and duplicate-event cases covered, if messaging changed
- [ ] Acceptance criteria from the spec section converted into tests

### Docs
- [ ] Glossary updated if a new term was introduced
- [ ] ADR written if an architectural decision was made
```

---

## Reviewing

Reviewers, look for these specifically. They are the things that are cheap to fix in review and
expensive to fix in production.

1. **A business rule that drifted into the BFF or building-blocks.** It will be copied by the next
   person and there will be two versions of the rule within a month.
2. **A hard-coded threshold.** Every OTP expiry, attempt limit, session TTL and cooling-off period
   is configuration. A number in code is a deploy every time Compliance changes their mind.
3. **A publish outside the outbox.** Looks fine, works in testing, loses events in production
   exactly when it matters.
4. **A consumer that assumes ordering.** "Passcode created" can arrive before "phone verified".
5. **Something sensitive in a log or event.** The redaction lint catches declared schema fields. It
   does not catch a `_logger.LogInformation("code {Code}", otp)`.
6. **An invented value where the spec says PLACEHOLDER.** A plausible-looking number buried in code
   is worse than a blank, because nobody will ever question it.

---

## Commit messages

```
feat(identity): enforce OTP resend cooldown from server clock
fix(bff): stop leaking provider status in transfer response
docs(adr): record repository topology decision
chore(ci): add service isolation check
```

Format: `type(scope): imperative summary`. Scope is the service or area.

---

## What not to do

- **Do not edit `ErrorCodes.cs` by hand without editing the catalogue.** CI fails. This is on
  purpose: if the two disagree, customers see the wrong message.
- **Do not add a NuGet version to a `.csproj`.** Versions live in `Directory.Packages.props`.
- **Do not suppress a warning to make the build pass.** Warnings are errors here deliberately. If
  a suppression is genuinely right, comment why on the line.
- **Do not reference another service's project or query its database.** Use its API or its events.
  This is checked by CI, but the check exists because the temptation is real when you are in a hurry.
- **Do not skip the idempotency key because "this endpoint is safe to repeat".** It is safe today.
  It grows a side effect in six months and nobody revisits the decision.
