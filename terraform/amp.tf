###############################################################################
# amp.tf
#
# Amazon Managed Prometheus (AMP) — provides a HA, multi-AZ Prometheus
# control plane managed by AWS. We use AMP because:
#
#   1. Long-term metric storage with 150-day retention out of the box.
#   2. Native integration with the Sigv4 OTel exporter.
#   3. PromQL-compatible query API consumed by Grafana and alert rules.
#
# We provision a single workspace with logging enabled and an optional
# alert manager definition that lands later (Day 46) when the SLO alerts
# are wired up.
###############################################################################

resource "aws_prometheus_workspace" "this" {
  alias = "${local.name_prefix}-${var.amp_workspace_alias}"

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp_logs.arn}:*"
  }

  tags = merge(local.common_tags, {
    Component = "amp-workspace"
  })
}

###############################################################################
# Alert manager definition. AWS expects a YAML body matching the upstream
# Prometheus alertmanager format. We surface this as a variable so the
# detailed routing rules (Day 46) can drop in without re-touching this file.
###############################################################################

resource "aws_prometheus_alert_manager_definition" "this" {
  count        = var.amp_alert_manager_definition == "" ? 0 : 1
  workspace_id = aws_prometheus_workspace.this.id
  definition   = var.amp_alert_manager_definition
}

###############################################################################
# Default rule-group namespace. Even on Day 43 we install a sentinel rule
# ("DeadMansSwitch") so operators can verify end-to-end alert delivery the
# moment the workspace exists. Real SLO rules append to this namespace later.
###############################################################################

resource "aws_prometheus_rule_group_namespace" "default" {
  name         = "${local.name_prefix}-default"
  workspace_id = aws_prometheus_workspace.this.id

  data = yamlencode({
    groups = [
      {
        name     = "dead-mans-switch"
        interval = "30s"
        rules = [
          {
            alert = "DeadMansSwitch"
            expr  = "vector(1)"
            labels = {
              severity = "none"
              purpose  = "verify-alert-pipeline"
            }
            annotations = {
              summary = "Alerting pipeline is alive"
              description = join(" ", [
                "This alert is always firing. Its absence indicates the AMP",
                "alerting pipeline or downstream notifier is broken.",
              ])
              runbook_url = "https://github.com/shivajichaprana/aws-observability-stack/blob/main/docs/runbooks/dead-mans-switch.md"
            }
          },
        ]
      },
    ]
  })
}

###############################################################################
# IRSA role for OTel Collector remote_write to AMP. The Collector running on
# EKS assumes this role through the OIDC provider. Day 44 wires up the
# Kubernetes ServiceAccount that maps to it.
###############################################################################

resource "aws_iam_policy" "amp_remote_write" {
  name        = "${local.name_prefix}-amp-remote-write"
  description = "Allow OTel Collector / Prometheus agent to remote_write to the AMP workspace"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AMPRemoteWrite"
        Effect = "Allow"
        Action = [
          "aps:RemoteWrite",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
        ]
        Resource = aws_prometheus_workspace.this.arn
      },
    ]
  })

  tags = local.common_tags
}
