# ADR 0002 — Infrastructure baseline

**Status:** Accepted
**Date:** 2026-09-06
**Deciders:** Engineering / Architecture
**Related:** ADR 0001 (repository topology), Baseline 2.0 §2 (AWS, ECS Fargate, Aurora)

---

## Context

Baseline 2.0 fixes the platform as AWS, ECS Fargate, PostgreSQL, Redis, SQS and
EventBridge. It does not specify network layout, database sizing model, queue
topology, key management or state handling. Those choices are made here.

The constraint that shapes most of them: this is a cross-border payments platform
holding customer identity data, but at Step 2 it has no production traffic and no
measured load. Decisions must be safe enough for regulated data and cheap enough
that dev does not cost more than the team.

---

## Decisions

### 1. Three subnet tiers, not two

Public (load balancer, NAT), private (ECS tasks), isolated (Aurora, Redis).

The isolated tier's route table has **no default route at all** — no NAT, no
gateway. The database is unreachable from the internet by construction rather than
by firewall rule. A security group can be misconfigured in a hurry; a missing route
cannot be misconfigured by accident.

Cost: nothing. It is three more route table associations.

### 2. /20 subnets, distinct VPC CIDR per environment

dev `10.20.0.0/16`, staging `10.30.0.0/16`, prod `10.40.0.0/16`.

Fargate tasks each consume an ENI and therefore an IP. A `/24` gives 251 usable
addresses, which a rolling deploy across several services can exhaust. A `/20`
gives 4,091.

Non-overlapping CIDRs mean the VPCs can be peered or attached to a transit gateway
later. Renumbering a live VPC means recreating everything in it.

### 3. Aurora PostgreSQL Serverless v2

Nobody knows the load shape yet. Serverless v2 scales between a floor and a ceiling
with no maintenance window; a provisioned instance sized today would be a guess
that is either wasteful or too small.

The ACU ceiling doubles as a cost guard: a runaway query cannot scale the bill
without limit, and an alarm fires when capacity pins at the ceiling.

**Reversible.** Moving to provisioned instances is a change to `modules/data`.

### 4. Schema per service on one cluster

Seven services, seven schemas, seven roles, one Aurora cluster.

Seven clusters would be architecturally cleaner and roughly seven times the cost
for an estate with no traffic. Isolation is preserved by mechanism rather than by
convention:

- Each service has its own role, and its `search_path` is pinned to its own schema.
- The application role has no `CREATE` on any schema, including its own.
- The application role cannot see other schemas at all.

Cross-service SQL is therefore not merely discouraged, it is unavailable. Moving a
schema to a dedicated cluster later is a connection-string change plus a data copy.

**Alternative rejected:** shared schema with table prefixes. It relies entirely on
discipline, and discipline fails under deadline.

### 5. One SQS queue per (event, consumer) pair

A shared queue means a slow or failing consumer delays every other consumer of the
same event. Audit falling behind must never delay the journey projector, because
that projector is what moves a customer out of `SETUP_COMPLETING`.

Each queue gets its own DLQ, its own alarm on dead letters (threshold: one
message, not a percentage — a dead-lettered domain fact is never routine) and its
own backlog-age alarm.

An `unrouted-events` queue catches anything matching no rule. An empty queue is the
healthy state; anything in it means a producer typo or a missing subscription.

### 6. EventBridge archive with 90-day retention

Completes the outbox story. The outbox guarantees an event is published; the
archive guarantees it can be replayed. If a consumer had a bug for two days, you
fix the bug and replay rather than reconstructing state by hand.

Ninety days is longer than any realistic "we only just noticed" window and short
enough to bound cost.

### 7. API Gateway is the only public surface

`internet → API Gateway → VPC Link → internal ALB → ECS task`

One place for throttling, WAF association and access logging. The ALB has no
public IP, so an ALB listener misconfiguration cannot expose a service.

API Gateway throttling is a blunt account-level guard, not the real rate limiting.
Per-customer limits (OTP resend, recovery attempts) belong in Identity & Access
where the customer is known.

### 8. Four KMS keys by data class

`data`, `secrets`, `logs`, `messaging`. All with rotation and a 30-day deletion
window.

One account key would be simpler and would mean any principal able to decrypt logs
is also able to decrypt the customer database. Key policy is the last line of
defence; splitting by data class limits what a single compromised role reaches.

### 9. Terraform creates secret containers, never secret values

A value in a `.tf` or `.tfvars` file ends up in state, in plan output and in the PR
diff. Terraform creates the container with a placeholder and
`ignore_changes = [secret_string]`; values are set with the AWS CLI.

The Aurora master password uses `manage_master_user_password`, so RDS generates and
stores it and it never enters state at all.

### 10. S3 native state locking, no DynamoDB

Terraform 1.10 added `use_lockfile = true`. This removes a table, its IAM policy
and its cost. Requires Terraform ≥ 1.10, which `required_version` enforces.

### 11. Environment-differentiated resilience

| Setting | dev | prod | Why |
|---|---|---|---|
| NAT gateways | 1 | 3 | ~£70/month against a single point of failure for all egress, including payout partners |
| Interface endpoints | off | on | ~£130/month, but removes AWS API traffic from the NAT, which costs more at volume |
| Aurora instances | 1 | ≥2 | A failover needs somewhere to go |
| Redis replicas | 0 | ≥1 | Automatic failover |
| Fargate Spot | on | off | Spot reclaims with two minutes' notice — fine for dev, not for a payment in flight |
| Backup retention | 7d | 35d | |
| Deletion protection | off | on | |

The same modules build both. Only the variables differ, so a fix applied in dev is
the same code that runs in prod.

### 12. Immutable ECR tags

A tag cannot be repushed with different content. "Which code was live at 14:20?"
must have exactly one answer on a regulated platform.

---

## Consequences

**Positive**
- Database exposure requires a deliberate route change, not just a mistake.
- Cross-service SQL is unavailable rather than discouraged.
- Consumer failures are isolated and individually alarmed.
- Environments are the same code with different numbers.
- Dev idles at roughly £100/month.

**Negative**
- Schema-per-service means one cluster is a shared failure domain. Accepted for
  now, revisit when any service's load justifies its own.
- Serverless v2 does not scale to zero: the 0.5 ACU floor bills 24/7. Destroy dev
  when it is idle for long periods.
- Post-apply manual steps (secret values, database roles, alarm subscription) are
  easy to forget. Mitigated by the `next_steps` output.
- No WAF yet. Must land before go-live.

**Open**
- Multi-region and DR posture. RTO/RPO are still unowned — README §7.
- Retention schedules are PLACEHOLDER values pending Compliance.
- GitHub Actions OIDC deploy role arrives in Step 3.

---

## Revisit when

- Any single service's database load justifies its own cluster.
- Measured load makes provisioned Aurora cheaper than Serverless v2.
- Regulatory review requires data residency guarantees a single region cannot meet.
