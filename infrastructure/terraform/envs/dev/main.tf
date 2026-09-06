# ============================================================================
# Development environment
#
#   terraform init
#   terraform plan
#   terraform apply
#
# Read infrastructure/terraform/README.md before the first apply. There is a
# bootstrap stack that must run first, and a cost note you should look at.
#
# The subscriptions map below is the single place where the event topology is
# declared. It must match contracts/events/CATALOGUE.md — CI checks that it does.
# ============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "social-remit"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "social-remit-platform"
      CostCentre  = "engineering"
    }
  }
}

# ── Variables ───────────────────────────────────────────────────────────────

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "ci_role_arn" {
  description = "GitHub Actions OIDC role. PLACEHOLDER until the CI role is created."
  type        = string
}

locals {
  name_prefix = "social-remit-${var.environment}"

  tags = {
    Environment = var.environment
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Event topology — mirrors contracts/events/CATALOGUE.md.
  #
  # One entry per (consumer, event-group). Adding a consumer here without adding
  # it to the catalogue fails CI, and vice versa. That check exists because a
  # queue nobody documented is a queue nobody monitors.
  # ──────────────────────────────────────────────────────────────────────────
  subscriptions = {
    "customer-journey--identity" = {
      consumer = "customer-journey-identity"
      event_types = [
        "phone.verified",
        "passcode.configured",
        "profile.email_verified",
        "registered_phone.changed",
      ]
    }

    "notification--identity" = {
      consumer = "notification-identity"
      event_types = [
        "phone.challenge_issued",
        "device.registered",
        "device.revoked",
        "passcode.reset",
        "recovery.completed",
        "registered_phone.changed",
      ]
    }

    "notification--consent" = {
      consumer    = "notification-consent"
      event_types = ["communication.preference_changed"]
    }

    # Audit consumes everything. It is the compliance record, so its subscription
    # is deliberately broad and its retention deliberately long.
    "audit-reporting--all" = {
      consumer = "audit-reporting"
      event_types = [
        "registration.started", "prospect.created", "greeting.preference_saved",
        "service_intent.selected", "help.opened",
        "phone.challenge_issued", "phone.verified", "phone.challenge_failed",
        "legal.account_accepted", "communication.preference_changed",
        "profile.email_captured", "profile.email_verified",
        "passcode.configured", "authentication.succeeded", "authentication.failed",
        "device.registered", "device.revoked", "biometrics.preference_changed",
        "recovery.started", "recovery.completed", "registered_phone.changed",
        "passcode.reset",
      ]
      # Audit must not lose events. More attempts before the DLQ than a consumer
      # whose work can be reconstructed.
      max_receive_count = 10
    }

    "provider-integration--identity" = {
      consumer    = "provider-integration"
      event_types = ["prospect.created", "registered_phone.changed"]
    }
  }
}

# ── Modules ─────────────────────────────────────────────────────────────────

module "security" {
  source = "../../modules/security"

  name_prefix = local.name_prefix
  environment = var.environment
  tags        = local.tags
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr

  # Dev economics: one NAT instead of three saves roughly £70/month, and interface
  # endpoints are off because dev traffic never reaches the volume where they pay
  # for themselves. Both flip to the resilient setting in prod.
  single_nat_gateway         = true
  enable_interface_endpoints = false

  flow_log_bucket_arn = module.security.audit_bucket_arn
  tags                = local.tags
}

module "messaging" {
  source = "../../modules/messaging"

  name_prefix           = local.name_prefix
  environment           = var.environment
  messaging_kms_key_arn = module.security.kms_key_arns["messaging"]
  alarm_topic_arn       = module.platform.alarm_topic_arn
  subscriptions         = local.subscriptions
  tags                  = local.tags
}

module "platform" {
  source = "../../modules/platform"

  name_prefix           = local.name_prefix
  environment           = var.environment
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  logs_kms_key_arn      = module.security.kms_key_arns["logs"]
  event_bus_arn         = module.messaging.event_bus_arn

  enable_spot        = true
  log_retention_days = 30

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix                = local.name_prefix
  environment                = var.environment
  isolated_subnet_ids        = module.network.isolated_subnet_ids
  database_security_group_id = module.network.database_security_group_id
  cache_security_group_id    = module.network.cache_security_group_id
  data_kms_key_arn           = module.security.kms_key_arns["data"]
  secrets_kms_key_arn        = module.security.kms_key_arns["secrets"]
  alarm_topic_arn            = module.platform.alarm_topic_arn

  aurora_min_capacity   = 0.5
  aurora_max_capacity   = 4
  aurora_instance_count = 1
  cache_node_type       = "cache.t4g.micro"
  cache_replica_count   = 0

  tags = local.tags
}

module "artifacts" {
  source = "../../modules/artifacts"

  name_prefix         = local.name_prefix
  environment         = var.environment
  secrets_kms_key_arn = module.security.kms_key_arns["secrets"]
  ci_role_arn         = var.ci_role_arn
  tags                = local.tags
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "api_endpoint" {
  description = "Public base URL for the mobile app"
  value       = module.platform.api_endpoint
}

output "database_endpoint" {
  value     = module.data.cluster_endpoint
  sensitive = true
}

output "database_master_secret_arn" {
  description = "Read by the migration task only. No service uses these credentials."
  value       = module.data.master_secret_arn
}

output "redis_endpoint" {
  value     = module.data.redis_primary_endpoint
  sensitive = true
}

output "event_bus_name" { value = module.messaging.event_bus_name }
output "ecr_repository_urls" { value = module.platform.ecr_repository_urls }
output "ecs_cluster_name" { value = module.platform.cluster_name }
output "alarm_topic_arn" { value = module.platform.alarm_topic_arn }

output "codeartifact_npm_login" { value = module.artifacts.npm_login_command }
output "codeartifact_nuget_login" { value = module.artifacts.nuget_login_command }

output "next_steps" {
  value = <<-EOT

    Infrastructure is up. Before anything can run:

    1. Set the secret values (Terraform created empty containers on purpose):
         aws secretsmanager put-secret-value \
           --secret-id ${local.name_prefix}/security/installation-id-pepper \
           --secret-string "$(openssl rand -base64 48)"

    2. Create the per-service database roles:
         see db/platform/002_service_roles.sql

    3. Subscribe someone to the alarm topic — an alarm nobody receives is not an alarm:
         aws sns subscribe --topic-arn ${module.platform.alarm_topic_arn} \
           --protocol email --notification-endpoint you@socialremit.com

    Then move to Step 3: the service template and the Mobile BFF.
  EOT
}
