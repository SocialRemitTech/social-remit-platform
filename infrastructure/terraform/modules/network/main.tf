# ============================================================================
# Network
#
# Three subnet tiers, because a payments platform needs the database to be
# unreachable from the internet by construction, not by firewall rule:
#
#   public    — load balancer and NAT only. Has a route to the internet gateway.
#   private   — ECS tasks. Egress via NAT, no inbound from the internet.
#   isolated  — Aurora and Redis. NO route to a NAT or gateway at all. A
#               misconfigured security group cannot expose them, because there
#               is no path.
#
# CIDR blocks are deliberately distinct per environment so the VPCs can be peered
# or attached to a transit gateway later without renumbering. Renumbering a live
# VPC means recreating everything in it.
# ============================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

# ── Variables ───────────────────────────────────────────────────────────────

variable "name_prefix" {
  description = "e.g. social-remit-dev"
  type        = string
}

variable "vpc_cidr" {
  description = "dev 10.20.0.0/16, staging 10.30.0.0/16, prod 10.40.0.0/16"
  type        = string
}

variable "availability_zone_count" {
  description = "Three in every environment. Two AZs means losing one halves capacity; three means losing one costs a third."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = <<-EOT
    true in dev: one NAT instead of three saves roughly £70/month and the blast
    radius of an AZ failure in dev is a slower standup, not an outage.
    MUST be false in prod: a single NAT is a single point of failure for all
    outbound traffic, including calls to payout partners.
  EOT
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Interface endpoints keep AWS API traffic off the NAT. Each costs about £6/month
    per AZ, so roughly £130/month for the full set across three AZs — but they also
    remove NAT data-processing charges, which at volume exceeds that. Off in dev,
    on in prod.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ── Locals ──────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # /20 per subnet: 4,091 usable addresses. Fargate tasks each take an ENI and
  # therefore an IP, so a /24 (251 usable) runs out faster than teams expect
  # during a rolling deploy of many services.
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  isolated_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_count = var.single_nat_gateway ? 1 : length(local.azs)
}

# ── VPC ─────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# ── Subnets ─────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  # Public IPs are assigned only to the load balancer and NAT, which live here.
  # Nothing else is ever placed in a public subnet.
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_subnet" "isolated" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.isolated_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-isolated-${local.azs[count.index]}"
    Tier = "isolated"
  })
}

# ── NAT ─────────────────────────────────────────────────────────────────────

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags       = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
  depends_on = [aws_internet_gateway.this]
}

# ── Routing ─────────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per AZ so each private subnet uses the NAT in its own AZ.
# Sharing one table would send cross-AZ traffic and incur transfer charges.
resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = length(local.azs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Isolated subnets get a route table with NO default route. This is the whole
# point of the tier — the database has no path off the VPC.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-isolated" })
}

resource "aws_route_table_association" "isolated" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# ── VPC endpoints ───────────────────────────────────────────────────────────

# Gateway endpoint for S3. Free, and it removes all S3 traffic from the NAT —
# which for container image layers and log shipping is the bulk of it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.isolated.id]
  )

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

data "aws_region" "current" {}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpce"
  description = "Interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset([
    "ecr.api", "ecr.dkr", "logs", "secretsmanager", "kms", "sqs", "events", "sts", "xray"
  ]) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.value}" })
}

# ── Security groups ─────────────────────────────────────────────────────────
#
# Rules reference other security groups rather than CIDR blocks. A CIDR rule says
# "anything at this address"; a group rule says "this specific role". When the
# subnets are re-carved, group rules keep working and stay accurate.

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Internal ALB fronting ECS services"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within the VPC (API Gateway reaches this via VPC Link)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "To ECS tasks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks"
  description = "Fargate tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Service-to-service within the VPC"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Outbound to AWS APIs, payout partners and providers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-tasks" })
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-database"
  description = "Aurora PostgreSQL"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "PostgreSQL from ECS tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # No egress rule. The database has no reason to originate a connection, and
  # denying it removes an exfiltration path.

  tags = merge(var.tags, { Name = "${var.name_prefix}-database" })
}

resource "aws_security_group" "cache" {
  name        = "${var.name_prefix}-cache"
  description = "ElastiCache Redis"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Redis from ECS tasks only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cache" })
}

# ── Flow logs ───────────────────────────────────────────────────────────────
#
# Required evidence for incident investigation and for most regulatory reviews.
# Rejected traffic only: accepted traffic at volume is expensive and rarely the
# thing you need when answering "what tried to reach the database?"

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT"
  log_destination_type = "s3"
  log_destination      = var.flow_log_bucket_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-flow-logs" })
}

variable "flow_log_bucket_arn" {
  description = "S3 bucket ARN for VPC flow logs"
  type        = string
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "isolated_subnet_ids" { value = aws_subnet.isolated[*].id }
output "availability_zones" { value = local.azs }

output "alb_security_group_id" { value = aws_security_group.alb.id }
output "ecs_tasks_security_group_id" { value = aws_security_group.ecs_tasks.id }
output "database_security_group_id" { value = aws_security_group.database.id }
output "cache_security_group_id" { value = aws_security_group.cache.id }
