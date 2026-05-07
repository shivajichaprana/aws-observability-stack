###############################################################################
# amg.tf
#
# Amazon Managed Grafana (AMG) — fully managed Grafana with built-in AWS
# data source integrations. We provision:
#
#   1. The workspace itself (single-region, with AWS SSO authentication).
#   2. A workspace IAM role granting the workspace read-access to AMP,
#      CloudWatch, X-Ray, and Athena.
#   3. License association (Grafana Enterprise vs Community Edition).
#   4. SAML configuration block (only applied if SAML is in the providers list).
###############################################################################

resource "aws_grafana_workspace" "this" {
  name                     = "${local.name_prefix}-grafana"
  description              = "Primary Grafana workspace for ${local.name_prefix} environment"
  account_access_type      = var.amg_account_access_type
  authentication_providers = var.amg_authentication_providers
  permission_type          = "SERVICE_MANAGED"
  data_sources             = var.amg_data_sources
  notification_destinations = var.amg_notification_destinations
  role_arn                 = aws_iam_role.amg_workspace.arn

  # Pin Grafana to a recent stable major version. Bumping this triggers a
  # rolling restart of the workspace, so coordinate with on-call before
  # touching it.
  grafana_version = "10.4"

  tags = merge(local.common_tags, {
    Component = "amg-workspace"
  })
}

###############################################################################
# Workspace service role.
#
# AMG assumes this role to read data from AWS data sources (AMP, CloudWatch,
# X-Ray, Athena, Timestream, etc.). We grant only the read APIs each data
# source actually needs.
###############################################################################

data "aws_iam_policy_document" "amg_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "amg_workspace" {
  name               = "${local.name_prefix}-amg-workspace"
  description        = "Service role assumed by Amazon Managed Grafana for cross-service data sources"
  assume_role_policy = data.aws_iam_policy_document.amg_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "amg_workspace" {
  # Amazon Managed Prometheus — read-only PromQL access.
  statement {
    sid = "AMPRead"
    actions = [
      "aps:ListWorkspaces",
      "aps:DescribeWorkspace",
      "aps:QueryMetrics",
      "aps:GetLabels",
      "aps:GetSeries",
      "aps:GetMetricMetadata",
    ]
    resources = ["*"]
  }

  # CloudWatch metrics + logs read access.
  statement {
    sid = "CloudWatchRead"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
    ]
    resources = ["*"]
  }

  # X-Ray traces read access.
  statement {
    sid = "XRayRead"
    actions = [
      "xray:BatchGetTraces",
      "xray:GetServiceGraph",
      "xray:GetTraceGraph",
      "xray:GetTraceSummaries",
      "xray:GetGroups",
      "xray:GetGroup",
      "xray:GetTimeSeriesServiceStatistics",
      "xray:GetInsightSummaries",
      "xray:GetInsight",
      "xray:GetInsightEvents",
      "xray:GetInsightImpactGraph",
    ]
    resources = ["*"]
  }

  # Discover EC2 / RDS / Lambda / EKS resources that show up in dashboards.
  statement {
    sid = "ResourceDiscovery"
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "rds:DescribeDBInstances",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "amg_workspace" {
  name   = "${local.name_prefix}-amg-workspace-policy"
  role   = aws_iam_role.amg_workspace.id
  policy = data.aws_iam_policy_document.amg_workspace.json
}

###############################################################################
# Role assignments — translate IAM role ARNs into Grafana ADMIN / EDITOR
# membership. Useful when teams keep their personnel in a directory other
# than AWS SSO and instead rely on AssumeRole flows.
#
# NOTE: this resource only takes effect when AMG is configured with
# SAML or AWS_SSO; for IAM-Identity-Center-managed workspaces, role
# bindings happen in IAM Identity Center group assignments.
###############################################################################

resource "aws_grafana_role_association" "admin" {
  count        = length(var.amg_admin_role_arns) == 0 ? 0 : 1
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  user_ids     = []
  group_ids    = var.amg_admin_role_arns
}

resource "aws_grafana_role_association" "editor" {
  count        = length(var.amg_editor_role_arns) == 0 ? 0 : 1
  workspace_id = aws_grafana_workspace.this.id
  role         = "EDITOR"
  user_ids     = []
  group_ids    = var.amg_editor_role_arns
}
