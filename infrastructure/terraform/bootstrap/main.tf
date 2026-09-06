# ============================================================================
# State backend bootstrap — run ONCE per AWS account, before anything else.
#
# Chicken-and-egg: Terraform needs somewhere to store state, and that somewhere
# has to be created by something. This stack creates it using LOCAL state, then
# migrates itself into the bucket it just made.
#
#   cd infrastructure/terraform/bootstrap
#   terraform init
#   terraform apply -var="environment=dev"
#   terraform init -migrate-state    # answer "yes"
#
# After that, never touch this stack again unless you are onboarding a new account.
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
      Stack       = "bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region. eu-west-2 (London) keeps UK customer data in the UK, which matters for the FCA-regulated side of the business."
  type        = string
  default     = "eu-west-2"
}

variable "environment" {
  description = "dev | staging | prod"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "social-remit-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

# ----------------------------------------------------------------------------
# KMS key for state encryption
#
# Terraform state contains resource identifiers, ARNs and — despite best efforts —
# occasionally sensitive values. It is treated as a secret store.
# ----------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state for ${var.environment}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/social-remit-${var.environment}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# ----------------------------------------------------------------------------
# State bucket
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # State is not reproducible. Losing it means Terraform no longer knows what it
  # manages, and you reconcile a live production estate by hand.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    # Keep a year of history: enough to recover from a bad apply discovered late,
    # without paying to store every version forever.
    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any request that is not TLS. Without this, a misconfigured client can read
# state over plain HTTP.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ----------------------------------------------------------------------------
# NOTE ON LOCKING
#
# There is deliberately no DynamoDB table here. Terraform 1.10 added native S3
# state locking via `use_lockfile = true` in the backend config, which removes an
# entire resource, its IAM policy and its cost. See envs/*/backend.tf.
#
# If you are pinned below 1.10 for some reason, you need a DynamoDB table with a
# `LockID` string hash key and the legacy `dynamodb_table` backend argument.
# ----------------------------------------------------------------------------

output "state_bucket" {
  description = "Put this in envs/<env>/backend.tf"
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "backend_config" {
  description = "Copy-paste into envs/<env>/backend.tf"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "${var.environment}/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        kms_key_id   = "${aws_kms_key.state.arn}"
        use_lockfile = true
      }
    }
  EOT
}
