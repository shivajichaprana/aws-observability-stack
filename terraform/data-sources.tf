###############################################################################
# data-sources.tf
#
# Grafana data-source provisioning. AMG can auto-discover AWS data sources
# through the workspace IAM role, but the data source must still be created
# inside Grafana before dashboards can reference it. We use the grafana/grafana
# Terraform provider to create the AMP and CloudWatch data sources idempotently.
#
# This file is gated on var.grafana_url + var.grafana_api_key being populated,
# which happens AFTER the workspace exists. The bootstrap workflow:
#
#   terraform apply -target=aws_grafana_workspace.this
#   # populate grafana_url + grafana_api_key from outputs / Secrets Manager
#   terraform apply
###############################################################################

locals {
  grafana_provisioning_enabled = var.grafana_url != "" && var.grafana_api_key != ""
}

# ---------------------------------------------------------------------------
# Amazon Managed Prometheus data source
# ---------------------------------------------------------------------------

resource "grafana_data_source" "amp" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  type = "prometheus"
  name = "amp-${var.amp_workspace_alias}"
  url  = aws_prometheus_workspace.this.prometheus_endpoint

  # AMG signs requests with SigV4 against the AMP workspace ARN. The
  # workspace IAM role provisioned in amg.tf already has aps:QueryMetrics.
  json_data_encoded = jsonencode({
    httpMethod    = "POST"
    sigV4Auth     = true
    sigV4AuthType = "default"
    sigV4Region   = local.region
    timeInterval  = "30s"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch data source — used by the RDS, Lambda, and ALB dashboards. We
# default to the same region as the rest of the stack but expose region in
# json_data so dashboards can override per panel via $region template var.
# ---------------------------------------------------------------------------

resource "grafana_data_source" "cloudwatch" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  type = "cloudwatch"
  name = "cloudwatch-${local.region}"

  json_data_encoded = jsonencode({
    authType      = "default"
    defaultRegion = local.region
    customMetricsNamespaces = join(",", [
      "Custom",
      "AWS/Usage",
      "ContainerInsights",
    ])
  })
}

# ---------------------------------------------------------------------------
# X-Ray data source — separate from CloudWatch even though both are AWS,
# because the panel plugin types differ. Lets dashboards link from a metric
# spike to a trace search seamlessly.
# ---------------------------------------------------------------------------

resource "grafana_data_source" "xray" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  type = "grafana-x-ray-datasource"
  name = "xray-${local.region}"

  json_data_encoded = jsonencode({
    authType      = "default"
    defaultRegion = local.region
  })
}

# ---------------------------------------------------------------------------
# Tag the AMP source as default. Most dashboards we ship select it implicitly.
# ---------------------------------------------------------------------------

resource "grafana_organization_preference" "default" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  home_dashboard_uid = ""
  theme              = "dark"
  timezone           = "UTC"
  week_start         = "monday"
}
