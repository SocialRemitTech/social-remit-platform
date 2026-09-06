# ============================================================================
# Messaging — EventBridge bus and per-consumer SQS queues
#
# The topology mirrors contracts/events/CATALOGUE.md exactly. Each declared
# (event, consumer) pair gets its own queue and its own dead-letter queue.
#
# One queue per consumer, not one shared queue: with a shared queue, a consumer
# that falls behind or fails delays every other consumer of the same event. With
# one each, a broken audit consumer cannot slow down the journey projector.
#
# The archive matters more than it looks. It is what makes the outbox story
# complete: if a consumer had a bug for two days, you fix the bug and replay the
# archive rather than reconstructing state by hand.
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
variable "messaging_kms_key_arn" { type = string }
variable "alarm_topic_arn" { type = string }

variable "subscriptions" {
  description = <<-EOT
    (event, consumer) pairs from contracts/events/CATALOGUE.md. Adding a consumer
    is a change here AND a change to the catalogue — the CI check that both agree
    is what stops the topology drifting from the documentation.

    Key format: "<consumer>--<event_type_with_underscores>"
  EOT

  type = map(object({
    consumer     = string
    event_types  = list(string)
    max_receive_count = optional(number, 5)
  }))
}

variable "archive_retention_days" {
  description = "0 means indefinite. 90 days covers any realistic replay window without unbounded cost."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ── Event bus ───────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "domain" {
  name = "${var.name_prefix}-domain"
  tags = merge(var.tags, { Name = "${var.name_prefix}-domain" })
}

resource "aws_cloudwatch_event_archive" "domain" {
  name             = "${var.name_prefix}-domain-archive"
  event_source_arn = aws_cloudwatch_event_bus.domain.arn
  retention_days   = var.archive_retention_days
  description      = "Replay source for consumer backfills and incident recovery."

  event_pattern = jsonencode({
    source = [{ prefix = "social-remit." }]
  })
}

# Any event that matches no rule at all. An empty queue here is the healthy state;
# anything arriving means a producer is publishing something no one subscribes to,
# which is usually a typo in an event type or a missing subscription.
resource "aws_sqs_queue" "unrouted" {
  name                       = "${var.name_prefix}-unrouted-events"
  kms_master_key_id          = var.messaging_kms_key_arn
  message_retention_seconds  = 1209600 # 14 days, the SQS maximum
  visibility_timeout_seconds = 60

  tags = merge(var.tags, { Name = "${var.name_prefix}-unrouted-events" })
}

# ── Per-consumer queues ─────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  for_each = var.subscriptions

  name                      = "${var.name_prefix}-${each.value.consumer}-dlq"
  kms_master_key_id         = var.messaging_kms_key_arn
  message_retention_seconds = 1209600

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-${each.value.consumer}-dlq"
    Consumer = each.value.consumer
    Role     = "dead-letter"
  })
}

resource "aws_sqs_queue" "consumer" {
  for_each = var.subscriptions

  name              = "${var.name_prefix}-${each.value.consumer}"
  kms_master_key_id = var.messaging_kms_key_arn

  # Must exceed the slowest handler. A handler that takes longer than this has its
  # message redelivered while still running — which is survivable because the inbox
  # deduplicates, but it wastes work and muddies the metrics.
  visibility_timeout_seconds = 60

  message_retention_seconds = 345600 # 4 days
  receive_wait_time_seconds = 20     # long polling: fewer empty receives, lower cost

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-${each.value.consumer}"
    Consumer = each.value.consumer
  })
}

# ── Rules ───────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "consumer" {
  for_each = var.subscriptions

  name           = "${var.name_prefix}-${each.key}"
  event_bus_name = aws_cloudwatch_event_bus.domain.name
  description    = "Routes ${join(", ", each.value.event_types)} to ${each.value.consumer}"

  # detail-type carries the eventType from the envelope. The producer sets it when
  # publishing, so the routing rule and the envelope stay in step.
  event_pattern = jsonencode({
    source        = [{ prefix = "social-remit." }]
    "detail-type" = each.value.event_types
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "consumer" {
  for_each = var.subscriptions

  rule           = aws_cloudwatch_event_rule.consumer[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.domain.name
  target_id      = replace(each.key, "_", "-")
  arn            = aws_sqs_queue.consumer[each.key].arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq[each.key].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each = var.subscriptions

  queue_url = aws_sqs_queue.consumer[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeRule"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.consumer[each.key].arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.consumer[each.key].arn }
      }
    }]
  })
}

# ── Alarms ──────────────────────────────────────────────────────────────────

# A message in a DLQ means a domain fact could not be applied. On a payments
# platform that is never routine, so the threshold is one, not a percentage.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = var.subscriptions

  alarm_name          = "${var.name_prefix}-${each.value.consumer}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0

  alarm_description = "Dead letters for ${each.value.consumer}. A domain event could not be applied — investigate before it compounds."
  alarm_actions     = [var.alarm_topic_arn]
  treat_missing_data = "notBreaching"

  dimensions = { QueueName = aws_sqs_queue.dlq[each.key].name }
  tags       = var.tags
}

# Age, not depth. A deep queue that is draining fast is fine; a shallow queue whose
# oldest message is twenty minutes old means the consumer is stuck.
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = var.subscriptions

  alarm_name          = "${var.name_prefix}-${each.value.consumer}-backlog-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900 # 15 minutes

  alarm_description  = "${each.value.consumer} is falling behind. Customers may be stuck in SETUP_COMPLETING."
  alarm_actions      = [var.alarm_topic_arn]
  treat_missing_data = "notBreaching"

  dimensions = { QueueName = aws_sqs_queue.consumer[each.key].name }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unrouted" {
  alarm_name          = "${var.name_prefix}-unrouted-events"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0

  alarm_description  = "An event matched no rule. Either a producer typo, or a subscription missing from the catalogue."
  alarm_actions      = [var.alarm_topic_arn]
  treat_missing_data = "notBreaching"

  dimensions = { QueueName = aws_sqs_queue.unrouted.name }
  tags       = var.tags
}

# ── Outputs ─────────────────────────────────────────────────────────────────

output "event_bus_name" { value = aws_cloudwatch_event_bus.domain.name }
output "event_bus_arn" { value = aws_cloudwatch_event_bus.domain.arn }

output "queue_urls" {
  value = { for k, v in aws_sqs_queue.consumer : k => v.url }
}

output "queue_arns" {
  value = { for k, v in aws_sqs_queue.consumer : k => v.arn }
}

output "dlq_arns" {
  value = { for k, v in aws_sqs_queue.dlq : k => v.arn }
}

output "queue_arns_by_consumer" {
  description = "Consumer -> its queue ARNs. Used to scope each task role to only its own queues."
  value = {
    for consumer in distinct([for s in var.subscriptions : s.consumer]) :
    consumer => [
      for k, s in var.subscriptions : aws_sqs_queue.consumer[k].arn if s.consumer == consumer
    ]
  }
}
