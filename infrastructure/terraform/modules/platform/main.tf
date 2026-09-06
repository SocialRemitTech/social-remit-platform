# ============================================================================
# Platform — ECS cluster, ECR, ingress and shared IAM
#
# Ingress path:
#
#   internet → API Gateway (HTTP API) → VPC Link → internal ALB → ECS task
#
# The ALB is internal and has no public IP. API Gateway is the only public
# surface, which gives one place for throttling, WAF association and access
# logging, and means an ALB misconfiguration cannot accidentally expose a service.
#
# This module creates the SHARED platform. Per-service task definitions and ECS
# services arrive in Step 3 via a reusable `service` module — there is nothing to
# deploy yet, and inventing task definitions for services that do not exist would
# be scaffolding nobody validates.
# ============================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

# ── Variables ───────────────────────────────────────────────────────────────

variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "logs_kms_key_arn" { type = string }

variable "services" {
  description = "Service names from README §3. Each gets an ECR repository, a log group and a task role."
  type        = list(string)
  default = [
    "mobile-bff",
    "identity-access",
    "customer-journey",
    "consent-legal",
    "notification",
    "audit-reporting",
    "provider-integration",
  ]
}

variable "log_retention_days" {
  description = "PLACEHOLDER: the real retention schedule is owned by Compliance."
  type        = number
  default     = 30
}

variable "enable_spot" {
  description = "FARGATE_SPOT in dev only. Spot tasks can be reclaimed with two minutes' notice, which is fine for dev and not for a payment in flight."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  is_production = var.environment == "prod"
}

# ── Alarm topic ─────────────────────────────────────────────────────────────
#
# Created here because every other module needs to publish to it. Subscriptions
# (email, PagerDuty, Slack) are added out of band — an email address in a .tf file
# becomes a PR comment thread every time someone leaves.

resource "aws_sns_topic" "alarms" {
  name              = "${var.name_prefix}-alarms"
  kms_master_key_id = var.logs_kms_key_arn
  tags              = merge(var.tags, { Name = "${var.name_prefix}-alarms" })
}

# ── ECR ─────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "service" {
  for_each = toset(var.services)

  name = "${var.name_prefix}/${each.value}"

  # Immutable tags. Without this, someone can repush `:v1.2.3` with different
  # content, and the image you tested is not the image running. On a regulated
  # platform, "which code was live at 14:20?" must have one answer.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.logs_kms_key_arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value}", Service = each.value })
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = toset(var.services)

  repository = aws_ecr_repository.service[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 30 tagged images — enough to roll back several releases."
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged layers after 7 days."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── ECS cluster ─────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}"

  setting {
    name  = "containerInsights"
    value = local.is_production ? "enhanced" : "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = var.logs_kms_key_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec.name
      }
    }
  }

  tags = merge(var.tags, { Name = var.name_prefix })
}

# ECS Exec sessions are how an engineer gets a shell inside a running task. That
# is a production access path, so it is logged and the log is retained.
resource "aws_cloudwatch_log_group" "exec" {
  name              = "/aws/ecs/${var.name_prefix}/exec"
  retention_in_days = 365
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = var.enable_spot ? ["FARGATE", "FARGATE_SPOT"] : ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = var.enable_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
    base              = 0
  }
}

# ── Service discovery ───────────────────────────────────────────────────────
#
# Services resolve each other as identity-access.social-remit.internal. A DNS name
# survives task replacement; an IP address does not.

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.name_prefix}.internal"
  description = "Internal service discovery"
  vpc         = var.vpc_id
  tags        = var.tags
}

# ── Log groups ──────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(var.services)

  name              = "/aws/ecs/${var.name_prefix}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(var.tags, { Service = each.value })
}

# ── IAM ─────────────────────────────────────────────────────────────────────

# Execution role: what ECS itself needs to START a task — pull the image, write
# the log stream, read the secrets injected as environment variables. Shared,
# because it is the same job for every service.
resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_extra" {
  name = "secrets-and-kms"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Task roles: what the APPLICATION may do once running. One per service, so a
# compromised notification service cannot read the identity service's queues.
# Per-service permissions are attached in Step 3 by the `service` module — the
# roles exist now so the trust policy and naming are settled.
resource "aws_iam_role" "task" {
  for_each = toset(var.services)

  name = "${var.name_prefix}-task-${each.value}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = merge(var.tags, { Service = each.value })
}

# Every service publishes to the bus and emits telemetry. Anything beyond that is
# service-specific and granted individually.
resource "aws_iam_role_policy" "task_baseline" {
  for_each = toset(var.services)

  name = "baseline"
  role = aws_iam_role.task[each.value].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishDomainEvents"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = var.event_bus_arn
      },
      {
        Sid      = "Telemetry"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid      = "OwnSecretsOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/${each.value}/*"
      }
    ]
  })
}

variable "event_bus_arn" { type = string }

# ── Internal ALB ────────────────────────────────────────────────────────────

resource "aws_lb" "internal" {
  name               = "${var.name_prefix}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [var.alb_security_group_id]

  drop_invalid_header_fields = true
  enable_deletion_protection = local.is_production

  # Long enough for a slow provider call, short enough to release a stuck
  # connection before it exhausts the pool.
  idle_timeout = 65

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# Default action is a hard 404. New services register their own rules; anything
# unmatched must not fall through to whichever service happens to be first.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = jsonencode({
        data  = null
        error = { code = "NOT_FOUND", copyKey = "error.generic.not_found", retryable = false }
      })
    }
  }
}

# ── API Gateway ─────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name_prefix}-vpclink"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [var.alb_security_group_id]
  tags               = var.tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "Public entry point. The mobile app talks only to this."

  # The mobile app is not a browser. No CORS configuration is defined, because
  # permitting cross-origin access to a payments API without a reason to is a
  # gratuitous widening of the attack surface.

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.http.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn

    # Correlation ID is captured on every request. It is the first thing anyone
    # asks for during an incident, and capturing it here means it exists even for
    # requests that never reached a service.
    format = jsonencode({
      requestId        = "$context.requestId"
      correlationId    = "$context.requestHeaderOverride.header.X-Correlation-Id"
      httpMethod       = "$context.httpMethod"
      path             = "$context.path"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integration.error"
      sourceIp         = "$context.identity.sourceIp"
      userAgent        = "$context.identity.userAgent"
      appVersion       = "$context.requestHeaderOverride.header.X-App-Version"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true

    # A blunt account-level guard, not the real rate limiting. Per-customer and
    # per-endpoint limits (OTP resend, recovery attempts) are enforced in
    # Identity & Access where the customer identity is known.
    throttling_burst_limit = local.is_production ? 2000 : 200
    throttling_rate_limit  = local.is_production ? 1000 : 100
  }

  tags = var.tags
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "cluster_name" { value = aws_ecs_cluster.this.name }
output "cluster_arn" { value = aws_ecs_cluster.this.arn }

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}

output "log_group_names" {
  value = { for k, v in aws_cloudwatch_log_group.service : k => v.name }
}

output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }

output "task_role_arns" {
  value = { for k, v in aws_iam_role.task : k => v.arn }
}

output "task_role_names" {
  value = { for k, v in aws_iam_role.task : k => v.name }
}

output "alb_arn" { value = aws_lb.internal.arn }
output "alb_dns_name" { value = aws_lb.internal.dns_name }
output "alb_listener_arn" { value = aws_lb_listener.http.arn }

output "service_discovery_namespace_id" { value = aws_service_discovery_private_dns_namespace.this.id }
output "service_discovery_namespace_name" { value = aws_service_discovery_private_dns_namespace.this.name }

output "api_endpoint" {
  description = "Public base URL. Point the mobile app here."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
