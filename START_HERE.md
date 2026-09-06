# START HERE

You have the Social Remit middleware repository. This page tells you where to go.

---

## Never seen this before?

**Read `GETTING_STARTED.md` and follow it top to bottom.** It installs your tools, starts a local
database, and verifies everything works. About 45 minutes, mostly downloads. It assumes no prior
C# and explains what each tool is for.

---

## Which document do I want?

| I want to... | Open |
|---|---|
| Set up my laptop and get something running | `GETTING_STARTED.md` |
| Understand why the code is structured this way | `docs/HOW_IT_WORKS.md` |
| Look up a word I do not know | `docs/GLOSSARY.md` |
| See the full build plan and what comes next | `README.md` |
| Make a change without breaking the mobile app | `CONTRIBUTING.md` |
| Know why the app and backend are separate repos | `docs/adr/0001-repository-topology.md` |
| See every endpoint the mobile app can call | `contracts/openapi/mobile-bff.v1.yaml` |
| See every event and who listens to it | `contracts/events/CATALOGUE.md` |
| See every error a customer can be shown | `contracts/errors/error-catalogue.json` |

**Suggested reading order for a new joiner:** `GETTING_STARTED.md` → `docs/HOW_IT_WORKS.md` →
`docs/GLOSSARY.md` → `README.md` → `CONTRIBUTING.md`.

---

## What is in this package

This is **Step 1 of 14**: the platform foundation.

There is deliberately **no running service yet**. What exists is the agreed shape of every API,
event and error, plus the shared plumbing every future service will inherit. Building services
before that foundation exists is the most reliable way to end up with a codebase nobody can change
safely by month three.

```
social-remit-platform/
├── START_HERE.md                    ← you are here
├── GETTING_STARTED.md               laptop setup, install commands, troubleshooting
├── README.md                        the 14-step build plan
├── CONTRIBUTING.md                  how to make a change
├── docker-compose.yml               local Postgres + Redis + fake AWS
├── Directory.Build.props            compiler settings for every project
├── Directory.Packages.props         one place where NuGet versions are declared
│
├── contracts/                       ★ THE SOURCE OF TRUTH
│   ├── openapi/mobile-bff.v1.yaml       25 endpoints the app may call
│   ├── events/envelope.schema.json      the shape of every event
│   ├── events/CATALOGUE.md              22 events, producers and consumers
│   └── errors/error-catalogue.json      27 error codes the app can render
│
├── building-blocks/                 shared plumbing — never business rules
│   ├── ...Api/ApiEnvelope.cs            the { data, meta, error } response shape
│   ├── ...Api/RequestContext.cs         correlation IDs and required headers
│   ├── ...Api/Idempotency.cs            stops double-taps doing work twice
│   ├── ...Messaging/EventEnvelope.cs    event wrapper + secret-leak guard
│   ├── ...Messaging/Outbox.cs           makes events impossible to lose
│   └── ...Messaging/Inbox.cs            makes duplicate deliveries harmless
│
├── db/platform/001_building_blocks.sql   the three tables every service gets
├── docs/                            explanations and decision records
├── scripts/verify.sh                run before every push
├── scripts/dev-db.sh                creates the local tables
└── .github/workflows/contracts.yml  the 6 CI checks
```

---

## The 60-second version of what this does

The mobile app currently decides too much for itself. It remembers the PIN, tracks whether KYC is
done, and decides which screen comes next. Anything the app decides, a customer can tamper with.
Anything only on the phone is lost with the phone.

This middleware takes over every one of those decisions. The app becomes a renderer: it asks
"where am I and what can I do?", and shows what the server says.

To do that safely on a platform that moves money, three things must be true, and all three are
built here in Step 1:

1. **A retry must not do the work twice.** → idempotency
2. **An event must never be lost.** → the outbox
3. **A duplicated event must be harmless.** → the inbox

`docs/HOW_IT_WORKS.md` explains each one in plain language, with the failure it prevents.

---

## Fastest possible check that things work

```bash
bash scripts/verify.sh
```

Expect `ALL CHECKS PASSED`. Items marked `−` are skipped because a tool is not installed yet or
because that part arrives in a later step — that is normal at Step 1.

---

## Two things to know before you write any code

1. **Contracts change before code, never after.** The mobile app is in an app store; you cannot
   force users to update. `CONTRIBUTING.md` explains the workflow.
2. **Nothing sensitive goes in a log, an event or an error.** No passcodes, OTPs, tokens, full
   phone numbers or email addresses. CI enforces part of this; the rest is on you.

---

## What is next

**Step 2** — Terraform infrastructure: the AWS account layout, networking, database, queues and
secrets. **Step 3** — the first running service.

The full plan, including which steps are blocked on outside input, is in `README.md` §2.
