# ============================================================================
# Artifacts — CodeArtifact
#
# Required by ADR 0001. The mobile app is a separate repository and consumes the
# API contracts as a published npm package; .NET services consume the same
# contracts as a NuGet package. Without a private registry there is nowhere to
# publish them, and the two-repo decision quietly degrades into copy-paste.
#
# Both repositories have a public upstream, so they also act as a pull-through
# cache. That means a build keeps working when npmjs.org has an outage, and a
# package that disappears upstream does not break a release.
# ============================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "secrets_kms_key_arn" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}

# One domain for all environments. Contract packages are versioned artifacts, not
# environment-specific config — publishing the same version twice to two domains
# is how "it worked in staging" starts.
resource "aws_codeartifact_domain" "this" {
  domain         = "social-remit"
  encryption_key = var.secrets_kms_key_arn
  tags           = merge(var.tags, { Name = "social-remit" })
}

# ── Upstream caches ─────────────────────────────────────────────────────────

resource "aws_codeartifact_repository" "npm_upstream" {
  domain     = aws_codeartifact_domain.this.domain
  repository = "npm-store"

  external_connections {
    external_connection_name = "public:npmjs"
  }

  description = "Pull-through cache for npmjs.org"
  tags        = var.tags
}

resource "aws_codeartifact_repository" "nuget_upstream" {
  domain     = aws_codeartifact_domain.this.domain
  repository = "nuget-store"

  external_connections {
    external_connection_name = "public:nuget-org"
  }

  description = "Pull-through cache for nuget.org"
  tags        = var.tags
}

# ── Publishing repositories ─────────────────────────────────────────────────

resource "aws_codeartifact_repository" "npm" {
  domain     = aws_codeartifact_domain.this.domain
  repository = "npm"

  upstream {
    repository_name = aws_codeartifact_repository.npm_upstream.repository
  }

  description = "@socialremit/api-contracts — generated TypeScript types and MSW mocks for the mobile app"
  tags        = var.tags
}

resource "aws_codeartifact_repository" "nuget" {
  domain     = aws_codeartifact_domain.this.domain
  repository = "nuget"

  upstream {
    repository_name = aws_codeartifact_repository.nuget_upstream.repository
  }

  description = "SocialRemit.Contracts and shared building-block packages"
  tags        = var.tags
}

# ── Access ──────────────────────────────────────────────────────────────────

# Read for anyone in the account, publish only for the CI role. A developer's
# laptop should never be able to publish a contract version — that is how an
# unreviewed contract reaches the mobile team.
resource "aws_codeartifact_repository_permissions_policy" "npm" {
  domain          = aws_codeartifact_domain.this.domain
  repository      = aws_codeartifact_repository.npm.repository

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ReadForAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "codeartifact:DescribePackageVersion",
          "codeartifact:GetPackageVersionReadme",
          "codeartifact:ListPackages",
          "codeartifact:ListPackageVersions",
          "codeartifact:ReadFromRepository"
        ]
        Resource = "*"
      },
      {
        Sid       = "PublishForCiOnly"
        Effect    = "Allow"
        Principal = { AWS = var.ci_role_arn }
        Action    = ["codeartifact:PublishPackageVersion", "codeartifact:PutPackageMetadata"]
        Resource  = "*"
      }
    ]
  })
}

variable "ci_role_arn" {
  description = "GitHub Actions OIDC role permitted to publish. PLACEHOLDER until the CI role exists."
  type        = string
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "domain" { value = aws_codeartifact_domain.this.domain }
output "domain_owner" { value = aws_codeartifact_domain.this.owner }
output "npm_repository" { value = aws_codeartifact_repository.npm.repository }
output "nuget_repository" { value = aws_codeartifact_repository.nuget.repository }

output "npm_login_command" {
  description = "Run this before npm install in a repo that consumes @socialremit packages."
  value       = "aws codeartifact login --tool npm --domain ${aws_codeartifact_domain.this.domain} --domain-owner ${aws_codeartifact_domain.this.owner} --repository ${aws_codeartifact_repository.npm.repository}"
}

output "nuget_login_command" {
  value = "aws codeartifact login --tool dotnet --domain ${aws_codeartifact_domain.this.domain} --domain-owner ${aws_codeartifact_domain.this.owner} --repository ${aws_codeartifact_repository.nuget.repository}"
}
