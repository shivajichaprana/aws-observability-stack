###############################################################################
# composite-alarms.tf
#
# CloudWatch *composite alarms* aggregate multiple child alarms into a single
# operator-facing signal. They exist for one reason: they cut alert fatigue.
#
# Why we use them:
#
#   * AMP alerts (`alerts/slo-*.yaml`) cover Prometheus-side signals - request
#     ratios, latency burn-rate, etc.
#   * CloudWatch alarms cover AWS-managed signals - RDS CPU, ALB target 5xx,
#     Lambda concurrency, EKS control-plane errors. These metrics never reach
#     AMP without an exporter and there's no good reason to ship them through
#     OTel just to alert on them.
#
# A *composite* alarm lets us OR/AND those child alarms together so on-call
# gets one page instead of three, with a single runbook link.
#
# Runbook URLs are attached as a CloudWatch *alarm description* (plain text)
# and a *tag* (`Runbook`) so the Slack notifier Lambda and the AMG dashboard
# can both pull the same link. We keep them in one place - `local.runbooks`
# below - so changing a runbook URL is a one-line edit.
#
# This file is paired with `scripts/inject-runbook-links.py`, which mirrors
# the same map into the Grafana alert annotations (so a person clicking
# "View runbook" in Grafana lands on the same page a person clicking through
# the Slack alert lands on).
###############################################################################

# -----------------------------------------------------------------------------
# Variables specific to composite alarming. Kept local so the file is
# self-contained and can be deleted/disabled without touching the rest
# of the project.
# -----------------------------------------------------------------------------

variable "composite_alarms_enabled" {
  description = "Master switch for the composite alarm layer. Disable in early dev environments where child alarm churn would page on-call too often."
  type        = bool
  default     = true
}

variable "runbook_base_url" {
  description = "Base URL prefix where runbook markdown is published. Trailing slash is stripped at evaluation time."
  type        = string
  default     = "https://github.com/shivajichaprana/aws-observability-stack/blob/main/docs/runbooks"

  validation {
    condition     = can(regex("^https?://", var.runbook_base_url))
    error_message = "runbook_base_url must start with http:// or https://."
  }
}

variable "monitored_services" {
  description = "List of HTTP services whose 5xx + latency alarms feed into the composite alarm. Each entry must match the Prometheus `job` label."
  type        = list(string)
  default     = ["frontend", "api", "checkout"]

  validation {
    condition     = length(var.monitored_services) > 0
    error_message = "monitored_services must contain at least one service."
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose node pressure alarms feed the composite alarm. Leave empty to skip node-pressure aggregation."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Single source of truth: alert name -> runbook slug.
#
# Keep this map in sync with the Grafana annotations injected by
# `scripts/inject-runbook-links.py`. The CI workflow (`ci(obs)` step,
# added on Day 48) runs the script in `--check` mode against this map
# to catch drift.
# -----------------------------------------------------------------------------

locals {
  runbook_base = trimsuffix(var.runbook_base_url, "/")

  # Map of *composite-alarm friendly-name* -> markdown filename (without .md).
  # The friendly name is what appears in the Slack alert subject and in the
  # composite alarm's name attribute, so keep it short and grep-able.
  runbook_slugs = {
    HighErrorRate = "high-error-rate"
    HighLatency   = "high-latency"
    NodePressure  = "node-pressure"
  }

  runbook_urls = {
    for k, v in local.runbook_slugs : k => "${local.runbook_base}/${v}.md"
  }

  # Tag added to every CloudWatch alarm and composite alarm. The Slack
  # notifier reads this and embeds it in the message attachment so on-call
  # can jump straight to the runbook.
  alarm_tags = merge(
    local.common_tags,
    {
      "Component" = "composite-alarms"
    },
  )
}

# -----------------------------------------------------------------------------
# Child alarm 1: per-service 5xx rate on the ALB target group.
#
# Triggers if the rolling 5-minute count of HTTP 5xx responses exceeds a
# configurable threshold. One alarm per service from `monitored_services`.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "service_5xx" {
  for_each = var.composite_alarms_enabled ? toset(var.monitored_services) : toset([])

  alarm_name          = "${local.name_prefix}-${each.key}-5xx-rate"
  alarm_description   = "5xx error rate exceeded threshold for service '${each.key}'. Runbook: ${local.runbook_urls["HighErrorRate"]}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_name = "HTTPCode_Target_5XX_Count"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Sum"

  dimensions = {
    # Convention: every workload exposes its ALB target group under a tag
    # `Service=<name>`. The ALB controller in eks-platform-baseline applies
    # this tag automatically from the Ingress object's `service` label.
    TargetGroup = "service/${each.key}"
  }

  alarm_actions = []
  ok_actions    = []

  tags = merge(local.alarm_tags, {
    Service = each.key
    Runbook = local.runbook_urls["HighErrorRate"]
  })
}

# -----------------------------------------------------------------------------
# Child alarm 2: per-service p95 latency on the ALB target group.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "service_latency_p95" {
  for_each = var.composite_alarms_enabled ? toset(var.monitored_services) : toset([])

  alarm_name          = "${local.name_prefix}-${each.key}-latency-p95"
  alarm_description   = "p95 target response time exceeded 0.5s for service '${each.key}'. Runbook: ${local.runbook_urls["HighLatency"]}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 0.5
  treat_missing_data  = "notBreaching"

  metric_name        = "TargetResponseTime"
  namespace          = "AWS/ApplicationELB"
  period             = 60
  extended_statistic = "p95"

  dimensions = {
    TargetGroup = "service/${each.key}"
  }

  tags = merge(local.alarm_tags, {
    Service = each.key
    Runbook = local.runbook_urls["HighLatency"]
  })
}

# -----------------------------------------------------------------------------
# Child alarm 3a: EKS node memory pressure (per cluster).
#
# Uses the Container Insights metric `node_memory_utilization`. The metric
# is published by the CloudWatch agent / OTel collector deployed on the
# cluster (`otel/collector-daemonset.yaml`) so this alarm assumes that
# pipeline is live.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "eks_node_memory" {
  count = var.composite_alarms_enabled && var.eks_cluster_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-${var.eks_cluster_name}-node-mem-pressure"
  alarm_description   = "Average node memory utilisation across cluster '${var.eks_cluster_name}' above 85%. Runbook: ${local.runbook_urls["NodePressure"]}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 85
  treat_missing_data  = "missing"

  metric_name = "node_memory_utilization"
  namespace   = "ContainerInsights"
  period      = 60
  statistic   = "Average"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = merge(local.alarm_tags, {
    Cluster = var.eks_cluster_name
    Runbook = local.runbook_urls["NodePressure"]
  })
}

# -----------------------------------------------------------------------------
# Child alarm 3b: EKS node CPU pressure (per cluster).
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "eks_node_cpu" {
  count = var.composite_alarms_enabled && var.eks_cluster_name != "" ? 1 : 0

  alarm_name          = "${local.name_prefix}-${var.eks_cluster_name}-node-cpu-pressure"
  alarm_description   = "Average node CPU utilisation across cluster '${var.eks_cluster_name}' above 80%. Runbook: ${local.runbook_urls["NodePressure"]}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 80
  treat_missing_data  = "missing"

  metric_name = "node_cpu_utilization"
  namespace   = "ContainerInsights"
  period      = 60
  statistic   = "Average"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  tags = merge(local.alarm_tags, {
    Cluster = var.eks_cluster_name
    Runbook = local.runbook_urls["NodePressure"]
  })
}

###############################################################################
# Composite alarms.
#
# A composite alarm fires when its `alarm_rule` expression evaluates true.
# The expression is a boolean over `ALARM(...)`, `OK(...)` or
# `INSUFFICIENT_DATA(...)` references to *other* alarms.
#
# We build three composite alarms - one per runbook - and OR-aggregate the
# matching child alarms into each.
###############################################################################

# -----------------------------------------------------------------------------
# HighErrorRate composite: ANY service emitting elevated 5xx counts.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_composite_alarm" "high_error_rate" {
  count = var.composite_alarms_enabled ? 1 : 0

  alarm_name        = "${local.name_prefix}-composite-HighErrorRate"
  alarm_description = "One or more services are returning elevated 5xx responses. Runbook: ${local.runbook_urls["HighErrorRate"]}"

  # Build "ALARM(a) OR ALARM(b) OR ALARM(c) ..." over the child alarm names.
  alarm_rule = join(
    " OR ",
    [for a in aws_cloudwatch_metric_alarm.service_5xx : "ALARM(\"${a.alarm_name}\")"],
  )

  alarm_actions   = [aws_sns_topic.alerts_high.arn]
  ok_actions      = [aws_sns_topic.alerts_high.arn]
  actions_enabled = true

  tags = merge(local.alarm_tags, {
    AlertName = "HighErrorRate"
    Runbook   = local.runbook_urls["HighErrorRate"]
    Severity  = "critical"
  })

  depends_on = [aws_cloudwatch_metric_alarm.service_5xx]
}

# -----------------------------------------------------------------------------
# HighLatency composite: ANY service p95 over threshold.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_composite_alarm" "high_latency" {
  count = var.composite_alarms_enabled ? 1 : 0

  alarm_name        = "${local.name_prefix}-composite-HighLatency"
  alarm_description = "One or more services are above their p95 latency budget. Runbook: ${local.runbook_urls["HighLatency"]}"

  alarm_rule = join(
    " OR ",
    [for a in aws_cloudwatch_metric_alarm.service_latency_p95 : "ALARM(\"${a.alarm_name}\")"],
  )

  alarm_actions   = [aws_sns_topic.alerts_low.arn]
  ok_actions      = [aws_sns_topic.alerts_low.arn]
  actions_enabled = true

  tags = merge(local.alarm_tags, {
    AlertName = "HighLatency"
    Runbook   = local.runbook_urls["HighLatency"]
    Severity  = "warning"
  })

  depends_on = [aws_cloudwatch_metric_alarm.service_latency_p95]
}

# -----------------------------------------------------------------------------
# NodePressure composite: CPU OR memory pressure on the EKS cluster.
# Only created when `eks_cluster_name` is set, since otherwise there are no
# child alarms to reference and CloudWatch rejects empty alarm rules.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_composite_alarm" "node_pressure" {
  count = var.composite_alarms_enabled && var.eks_cluster_name != "" ? 1 : 0

  alarm_name        = "${local.name_prefix}-composite-NodePressure"
  alarm_description = "EKS cluster '${var.eks_cluster_name}' showing sustained CPU or memory pressure. Runbook: ${local.runbook_urls["NodePressure"]}"

  alarm_rule = join(" OR ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.eks_node_memory[0].alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.eks_node_cpu[0].alarm_name}\")",
  ])

  alarm_actions   = [aws_sns_topic.alerts_high.arn]
  ok_actions      = [aws_sns_topic.alerts_high.arn]
  actions_enabled = true

  tags = merge(local.alarm_tags, {
    AlertName = "NodePressure"
    Runbook   = local.runbook_urls["NodePressure"]
    Severity  = "critical"
  })

  depends_on = [
    aws_cloudwatch_metric_alarm.eks_node_memory,
    aws_cloudwatch_metric_alarm.eks_node_cpu,
  ]
}

# -----------------------------------------------------------------------------
# Outputs. Consumed by:
#   * scripts/inject-runbook-links.py     (verifies the map is current)
#   * .github/workflows (Day 48 CI)       (publishes the map as a CI artefact)
# -----------------------------------------------------------------------------

output "composite_alarm_arns" {
  description = "Map of composite alarm name -> ARN. Empty when composite_alarms_enabled = false."
  value = var.composite_alarms_enabled ? merge(
    { for a in aws_cloudwatch_composite_alarm.high_error_rate : "HighErrorRate" => a.arn },
    { for a in aws_cloudwatch_composite_alarm.high_latency : "HighLatency" => a.arn },
    { for a in aws_cloudwatch_composite_alarm.node_pressure : "NodePressure" => a.arn },
  ) : {}
}

output "runbook_url_map" {
  description = "Authoritative map of alert friendly-name -> published runbook URL. The inject-runbook-links.py script consumes this map (via terraform output -json) to align Grafana annotations."
  value       = local.runbook_urls
}
