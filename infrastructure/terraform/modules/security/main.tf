# ============================================================================
# Security — KMS keys and secret containers
#
# Separate keys per data class rather than one account key. The reason is blast
# radius: a key policy is the last line of defence, and "the log-shipping role can
# decrypt logs" should not also mean "the log-shipping role can decrypt the
# customer database".
#
# Every key has rotation enabled and a 30-day deletion window. A shorter window
# is a foot-gun: deleting a key destroys the data encrypted under it, permanently
# and unrecoverably.
# ============================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  key_classes = {
    data      = "Customer data at rest — Aurora, Redis, S3 document storage"
    secrets   = "Secrets Manager — credentials, peppers, provider API keys"
    logs      = "CloudWatch Logs and audit trails"
    messaging = "SQS queues and EventBridge archive"
  }
}

resource "aws_kms_key" "this" {
  for_each = local.key_classes

  description             = "${var.name_prefix}: ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-${each.key}"
    DataClass = each.key
  })
}

resource "aws_kms_alias" "this" {
  for_each = local.key_classes

  name          = "alias/${var.name_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

# CloudWatch Logs needs explicit permission on the key, otherwise log group
# creation fails with an opaque access-denied that is easy to misdiagnose.
resource "aws_kms_key_policy" "logs" {
  key_id = aws_kms_key.this["logs"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_key_policy" "messaging" {
  key_id = aws_kms_key.this["messaging"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "EventBridgeToSQS"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })
}

# ----------------------------------------------------------------------------
# Secret containers
#
# Terraform creates the CONTAINER and never the VALUE. A secret value in a .tf
# file or a .tfvars file ends up in state, in the plan output, and in the PR
# diff. Values are set out of band:
#
#   aws secretsmanager put-secret-value \
#     --secret-id social-remit-dev/security/installation-id-pepper \
#     --secret-string "$(openssl rand -base64 48)"
#
# `ignore_changes = [secret_string]` on the initial version means a later
# terraform apply will not overwrite a rotated value with the placeholder.
# ----------------------------------------------------------------------------

locals {
  secrets = {
    "security/installation-id-pepper" = "HMAC pepper for hashing X-Device-Installation-Id. See RequestContext.cs."
    "security/passcode-pepper"        = "Pepper applied before the Argon2id KDF. PRE-GO-LIVE: parameters owned by Security."
    "security/jwt-signing-key"        = "Session token signing key."
    "providers/otp-sms"               = "SMS provider credentials. PLACEHOLDER: provider not yet selected."
    "providers/email"                 = "Transactional email provider credentials. PLACEHOLDER."
    "providers/fincode"               = "FinCode API credentials. PLACEHOLDER: blocked on FinCode documentation."
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name        = "${var.name_prefix}/${each.key}"
  description = each.value
  kms_key_id  = aws_kms_key.this["secrets"].arn

  # Long enough to recover from an accidental delete, short enough that a rotated
  # secret does not linger indefinitely.
  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.key, "/", "-")}" })
}

resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each = local.secrets

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = jsonencode({ placeholder = "SET_OUT_OF_BAND", note = each.value })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ----------------------------------------------------------------------------
# Flow log and audit archive bucket
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "audit" {
  bucket = "${var.name_prefix}-audit-${data.aws_caller_identity.current.account_id}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-audit" })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this["logs"].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER_IR"
    }

    # PLACEHOLDER: seven years is the common AML record-keeping expectation, but
    # the actual retention schedule is owned by Compliance and is unconfirmed.
    # Do not treat this number as approved.
    expiration {
      days = 2555
    }
  }
}

resource "aws_s3_bucket_policy" "audit_flow_logs" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "VpcFlowLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "VpcFlowLogsAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.audit.arn
      }
    ]
  })
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "kms_key_arns" {
  value = { for k, v in aws_kms_key.this : k => v.arn }
}

output "kms_key_ids" {
  value = { for k, v in aws_kms_key.this : k => v.key_id }
}

output "secret_arns" {
  value = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
}

output "secret_name_prefix" {
  description = "IAM policies scope secret access to this prefix"
  value       = var.name_prefix
}

output "audit_bucket_arn" { value = aws_s3_bucket.audit.arn }
output "audit_bucket_name" { value = aws_s3_bucket.audit.id }
