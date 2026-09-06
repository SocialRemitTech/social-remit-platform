# ADR 0001 — Repository topology

**Status:** Accepted
**Date:** 2026-09-04
**Deciders:** Engineering / Architecture
**Supersedes:** nothing
**Related:** Baseline 2.0 §2.5 (repository structure), §2.4 (microservice non-negotiables)

---

## Context

Social Remit has two codebases with almost nothing in common technically:

- A React Native mobile app (already built to prototype stage, 100+ screens).
- A C#/.NET 10 middleware estate of domain-aligned microservices on AWS ECS Fargate.

The question is whether they live in one repository or two, and where the API contracts live.

Baseline 2.0 §2.5 already mandates a monorepo **for the services**, with each service remaining
independently buildable, testable, deployable and versioned. It does not place the mobile app in
that tree.

---

## Decision

**Two repositories, with contracts owned by the platform and consumed as published artifacts.**

```
social-remit-platform          ← backend monorepo (this repo)
social-remit-mobile            ← React Native app
```

`/contracts` lives in `social-remit-platform` and is the single source of truth. On merge to
`main`, CI publishes two artifacts from it:

| Artifact | Registry | Consumed by |
|---|---|---|
| `@socialremit/api-contracts` | private npm | mobile app — generated TypeScript types, MSW mocks, error-code union |
| `SocialRemit.Contracts` | private NuGet (CodeArtifact) | .NET services and integration tests |

The mobile app **never hand-writes a request or response type**. It imports generated ones and
pins a contract version.

---

## Rationale

### Why not one repository

| Factor | Consequence of merging |
|---|---|
| Toolchains share nothing | Every backend PR runs Metro/Gradle/Xcode CI unless we adopt Nx, Turborepo or Bazel — real tooling debt for no delivery gain at current team size |
| Release cadence differs by orders of magnitude | Backend deploys many times a day; app releases pass store review in days and cannot be rolled back once installed. A single tag would mean two incompatible things |
| Rollback semantics differ | A bad backend deploy is reverted in minutes. A bad app build is in users' hands for weeks. These do not belong on one release train |
| Access boundary | The platform repo contains IaC, KMS policy, secret configuration and audit code. RN contractors and designers need the app repo, not that |
| Repo weight | The mobile repo carries large binary design assets; the platform repo is text. Merging punishes every backend clone and CI checkout |

### Why not three repositories (separate contracts repo)

A standalone contracts repo makes every API change a three-PR dance (contract → platform →
mobile) with no compensating benefit. Contracts belong to the platform because the platform is
what must honour them. The publishing step gives the mobile app a stable seam without a repo of
its own.

### What we give up, and the mitigation

The genuine advantage of one repo is the atomic cross-stack PR. We recover most of it:

1. Platform PR changes `contracts/openapi/mobile-bff.v1.yaml`.
2. CI publishes a **prerelease** (`1.3.0-rc.1`) from the PR branch.
3. Mobile PR bumps to the prerelease and implements against generated types.
4. Both merge; the prerelease is promoted.

A contract change that breaks the client fails the mobile build immediately, not in QA. That is
the property people actually want from a monorepo, and it does not require one.

---

## Structure inside the platform monorepo

```
/social-remit-platform
  SocialRemit.sln                 one solution — developer convenience only
  Directory.Build.props           shared compiler/analyzer settings, warnings as errors
  Directory.Packages.props        central package version management
  /contracts                      SOURCE OF TRUTH — published on merge
  /building-blocks                technical concerns only; never business rules
  /services
    /mobile-bff
      SocialRemit.MobileBff.csproj
      Dockerfile
      /db                         service-owned migrations
    /identity-access
    /customer-journey
    /consent-legal
    /notification
    /audit-reporting
    /provider-integration
  /db/platform                    outbox/inbox/idempotency — applied to every service DB
  /infrastructure/terraform
  /tests/{contract,integration,end-to-end}
  /docs/adr
```

One solution file gives one-click cross-service debugging. That convenience must not become
coupling, so three mechanisms enforce isolation:

1. **A service project may `ProjectReference` only `building-blocks/*`.** Never another service.
   Cross-service communication is versioned HTTP or events, full stop. Enforced by a CI check,
   not by code review.
2. **`Directory.Packages.props` pins every NuGet version centrally.** No service drifts onto its
   own Npgsql or AWS SDK build.
3. **Path-filtered CI.** A change under `services/identity-access/**` builds, tests and deploys
   only that service. A change under `building-blocks/**` or `contracts/**` builds everything,
   because it can affect everything.

---

## Consequences

**Positive**

- Backend and mobile release independently, which is what their rollback characteristics demand.
- Contract drift becomes a build failure rather than a QA finding.
- The platform repo's access boundary matches its secret and compliance exposure.
- Baseline 2.0 §2.5 is satisfied exactly as written.

**Negative**

- A cross-stack feature is two PRs and one version bump. Accepted: this is the honest cost of two
  release trains that already exist for other reasons.
- Requires a private npm registry and CodeArtifact (or equivalent) before Step 3. This is
  infrastructure work that must land in Step 2, not be discovered in Step 3.
- Someone must own contract version promotion. Assign it with service ownership at Step 2.

**Neutral**

- If the team later grows to the point where a build orchestrator is justified on its own merits,
  merging the repos becomes a tractable one-week job. Splitting a merged repo later is harder, so
  starting split is the reversible direction.

---

## Revisit when

- The team exceeds roughly 25 engineers and a build orchestrator is being adopted anyway.
- Contract version churn exceeds about one breaking change per sprint, making the two-PR dance a
  measured drag rather than a theoretical one.
