# Infrastructure

Terraform for the Social Remit platform. Written for someone who has not used
Terraform before.

**Read this whole page before your first `apply`.** It creates billable AWS
resources and there is an ordering requirement that is annoying to unpick if you
get it wrong.

---

## What Terraform is, in one paragraph

Terraform reads `.tf` files describing what should exist in AWS, compares that to
what does exist, and makes the difference. You never click in the AWS console.
The value is that the console is not the record — the repository is. Anyone can
read what production looks like, changes go through pull request, and rebuilding
an environment is one command rather than three days of archaeology.

---

## Layout

```
infrastructure/terraform/
  bootstrap/            run ONCE per AWS account — creates the state bucket
  modules/              reusable building blocks, no environment-specific values
    network/            VPC, three subnet tiers, NAT, endpoints, security groups
    security/           KMS keys, secret containers, audit bucket
    data/               Aurora PostgreSQL Serverless v2, ElastiCache Redis
    messaging/          EventBridge bus, archive, per-consumer SQS + DLQs
    platform/           ECS cluster, ECR, internal ALB, API Gateway, IAM
    artifacts/          CodeArtifact npm + NuGet repositories
  envs/
    dev/                wires the modules with dev-sized values
```

Modules take variables and produce outputs. Environments choose the values. The
same module builds dev and prod — the difference is one NAT versus three, 0.5
ACUs versus 32.

---

## Prerequisites

```bash
brew install terraform awscli        # macOS
terraform version                    # want 1.10 or newer
aws --version
```

You need AWS credentials with permission to create VPCs, RDS, ECS, IAM roles and
KMS keys. Confirm you are pointed at the right account before anything else — the
most expensive mistake here is applying to the wrong one:

```bash
aws sts get-caller-identity
```

---

## First-time setup

### 1. Bootstrap the state backend

Terraform stores what it has created in a "state file". That file has to live
somewhere durable and shared, or two engineers applying at once will corrupt each
other's work. The chicken-and-egg — Terraform needs a bucket, and something has to
create the bucket — is solved by a small stack that creates the bucket using local
state, then moves itself into it.

```bash
cd infrastructure/terraform/bootstrap
terraform init
terraform apply -var="environment=dev"
```

Copy the `backend_config` output into `envs/dev/backend.tf`, then migrate this
stack's own state into the bucket it just made:

```bash
terraform init -migrate-state      # answer "yes"
```

You will never touch this stack again unless you onboard a new AWS account.

### 2. Set the CI role placeholder

`envs/dev/terraform.tfvars` has a `ci_role_arn` placeholder. Until the GitHub
Actions OIDC role exists, point it at yourself so the CodeArtifact policy is valid:

```bash
aws sts get-caller-identity --query Arn --output text
```

### 3. Apply the environment

```bash
cd ../envs/dev
terraform init
terraform plan        # READ THIS. Every time.
terraform apply
```

`plan` shows exactly what will be created, changed or destroyed. Reading it is not
optional ceremony — it is the only thing standing between a typo and a deleted
database. Look specifically for anything marked **destroy** or **replace**.

First apply takes 15–25 minutes; Aurora is the slow part.

### 4. Post-apply steps

Terraform deliberately does not do these. The `next_steps` output lists them:

```bash
# Secret VALUES — Terraform created empty containers on purpose. A value in a
# .tf file ends up in state, in the plan output, and in the PR diff.
aws secretsmanager put-secret-value \
  --secret-id social-remit-dev/security/installation-id-pepper \
  --secret-string "$(openssl rand -base64 48)"

# Per-service database roles
psql "$MASTER_CONNECTION" -v ON_ERROR_STOP=1 -f ../../../db/platform/002_service_roles.sql

# Someone must actually receive the alarms
aws sns subscribe --topic-arn "$(terraform output -raw alarm_topic_arn)" \
  --protocol email --notification-endpoint you@socialremit.com
```

---

## What this costs

Rough monthly figures for **dev**, eu-west-2, at idle. Treat as an order of
magnitude, not a quote.

| Resource | Approx. £/month | Note |
|---|---|---|
| Aurora Serverless v2 (0.5 ACU floor) | 35 | Scales up under load; the floor is the idle cost |
| NAT Gateway ×1 | 30 | Plus data processing. Three in prod |
| ElastiCache t4g.micro | 11 | |
| ALB | 16 | Plus LCU charges |
| ECS Fargate | 0 | Nothing deployed until Step 3 |
| KMS ×4 keys | 4 | £1 per key |
| CloudWatch, SQS, EventBridge, ECR | 5–15 | Volume-dependent |
| **Total idle** | **~£100–110** | |

**Prod is materially different**: three NATs, interface endpoints, larger ACU
ceiling, Multi-AZ Redis, longer retention. Budget several times the dev figure.

Two things that surprise people:

- **NAT Gateway data processing** is charged per GB in *addition* to the hourly
  rate. That is why prod enables interface endpoints — they cost about £130/month
  but remove the AWS API traffic from the NAT, which at volume costs more.
- **Aurora Serverless v2 does not scale to zero.** The 0.5 ACU floor bills 24/7.
  If dev sits unused for weeks, destroy it rather than leave it running.

---

## Tearing down

```bash
cd envs/dev
terraform destroy
```

Expect it to take 10–20 minutes and to fail the first time. The usual causes:

- **The S3 audit bucket is not empty.** Terraform will not delete a bucket with
  objects in it. Empty it first, or accept that it stays.
- **`deletion_protection` on Aurora.** Off in dev, on in prod — deliberately. In
  prod, turning it off is a separate, deliberate, reviewed change.
- **KMS keys enter a 30-day pending-deletion window** rather than disappearing.
  They still bill during it. This is a safety feature: deleting a key destroys
  everything encrypted under it, permanently.

Never run `destroy` against prod. The state bucket has `prevent_destroy` set, but
that protects the bucket, not the environment.

---

## Making a change

1. Edit the module or the environment values.
2. `terraform plan` and read it.
3. Open a PR with the plan output pasted in.
4. Merge, then `terraform apply`.

Never change infrastructure in the AWS console. Terraform will not know, and the
next `apply` will either revert your change or fail confusingly. If you must make
an emergency console change, open a PR reflecting it the same day.

Before pushing:

```bash
cd ../../..           # repository root
bash scripts/verify.sh
```

The `tf-check.py` step catches module wiring errors — an input a module does not
declare, a missing required input, a reference to an output that does not exist —
without needing Terraform installed or a provider download.

---

## Design decisions

Recorded in `docs/adr/0002-infrastructure-baseline.md`. Read it before proposing a
change to the network layout or the database choice; the reasoning and the
alternatives considered are there.

Short version:

- **Three subnet tiers.** The database tier has no route off the VPC at all. A
  misconfigured security group cannot expose it, because there is no path.
- **Aurora Serverless v2.** Nobody knows the load shape yet. Scales without a
  maintenance window; switching to provisioned later is a file change.
- **Schema per service, one cluster.** Cost. Isolation is enforced by separate
  roles and `search_path`, and moving a schema to its own cluster is a
  connection-string change.
- **One queue per consumer.** A shared queue means one slow consumer delays all
  the others.
- **API Gateway is the only public surface.** The ALB is internal.
- **S3 native state locking.** Terraform 1.10+. No DynamoDB table needed.

---

## Not here yet

| Thing | Arrives in |
|---|---|
| ECS task definitions and services | Step 3, via a reusable `service` module |
| GitHub Actions OIDC deploy role | Step 3 |
| WAF on API Gateway | Before go-live |
| Staging and prod environments | Copy `envs/dev`, change the sizing variables |
| Multi-region or DR posture | Open gap — see README §7 |
