###############################################################################
# dashboards.tf
#
# Imports the four curated Grafana dashboards for this stack into the Managed
# Grafana workspace. Each dashboard JSON ships in ../dashboards/ and uses
# ${DS_AMP} / ${DS_CW} placeholders for its primary data source. We rewrite
# those placeholders to the actual data source UIDs that data-sources.tf
# created, so the dashboards render correctly the moment Grafana imports them.
#
# All resources are gated on local.grafana_provisioning_enabled (set when the
# operator has supplied a grafana_url + grafana_api_key via Terraform vars).
# The bootstrap workflow in docs/quickstart.md documents how to obtain those.
###############################################################################

# ---------------------------------------------------------------------------
# Folder layout. We group dashboards into "Platform" (cluster-wide / managed
# AWS services) and "Workloads" (per-service RED dashboards) so on-call has
# a clean tree to navigate during an incident.
# ---------------------------------------------------------------------------

resource "grafana_folder" "platform" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  title = "Platform"
}

resource "grafana_folder" "workloads" {
  count = local.grafana_provisioning_enabled ? 1 : 0

  title = "Workloads"
}

# ---------------------------------------------------------------------------
# Helper locals.
#
# The dashboard JSON files reference data sources by template variable
# placeholders (${DS_AMP}, ${DS_CW}). When we import via the Grafana API,
# Grafana looks up the named template variable in the dashboard's templating
# list and substitutes the UID at render time. To keep that contract simple
# we leave the JSON exactly as Grafana would export it and only inject the
# *current* data source UIDs into the `templating.list[].current` field via a
# light JSON post-process. This avoids brittle regex-based string replacement
# while still producing a one-click-importable artifact.
# ---------------------------------------------------------------------------

locals {
  # Path to the dashboards/ directory at repo root, relative to the terraform/
  # directory. Using path.module keeps this stable when the stack is consumed
  # as a Terraform module from another project.
  _dashboards_dir = "${path.module}/../dashboards"

  # Data source UIDs Grafana assigned. These are populated lazily from the
  # grafana_data_source resources; with count=0 (provisioning disabled) the
  # try() falls through to safe placeholders so `terraform validate` still
  # works in CI environments that don't have a live Grafana endpoint.
  _amp_uid = try(grafana_data_source.amp[0].uid, "amp-placeholder")
  _cw_uid  = try(grafana_data_source.cloudwatch[0].uid, "cloudwatch-placeholder")

  # Mapping of dashboard config-name to source file. The config-name becomes
  # part of the Terraform resource address, so keep it stable across releases
  # — renaming will recreate the dashboard and lose Grafana-side annotations.
  dashboards = {
    eks_cluster = {
      file        = "${local._dashboards_dir}/eks-cluster.json"
      folder_kind = "platform"
      uses        = ["amp"]
    }
    workload_golden_signals = {
      file        = "${local._dashboards_dir}/workload-golden-signals.json"
      folder_kind = "workloads"
      uses        = ["amp"]
    }
    rds = {
      file        = "${local._dashboards_dir}/rds.json"
      folder_kind = "platform"
      uses        = ["cloudwatch"]
    }
    lambda = {
      file        = "${local._dashboards_dir}/lambda.json"
      folder_kind = "platform"
      uses        = ["cloudwatch"]
    }
  }
}

# ---------------------------------------------------------------------------
# Dashboard resources.
#
# We use replace() to inject the live data-source UIDs into the JSON before
# Grafana imports it. The placeholder syntax mirrors what Grafana writes when
# you Export → "Export for sharing externally", so importing the JSON file
# directly into a dev Grafana also works without modification.
# ---------------------------------------------------------------------------

resource "grafana_dashboard" "this" {
  for_each = local.grafana_provisioning_enabled ? local.dashboards : {}

  config_json = replace(
    replace(
      file(each.value.file),
      "$${DS_AMP}", local._amp_uid,
    ),
    "$${DS_CW}", local._cw_uid,
  )

  folder = (
    each.value.folder_kind == "platform"
    ? grafana_folder.platform[0].id
    : grafana_folder.workloads[0].id
  )

  overwrite = true
  message   = "Imported by Terraform — aws-observability-stack/${each.key}"

  # Make sure the data sources Grafana needs at first-paint exist before we
  # try to import the dashboard, otherwise the dashboard renders with
  # "Data source not found" panels until the next refresh.
  depends_on = [
    grafana_data_source.amp,
    grafana_data_source.cloudwatch,
  ]
}

# ---------------------------------------------------------------------------
# Outputs — surface the dashboard URLs so the bootstrap workflow can post
# them to a Slack channel or paste them into the project README.
# ---------------------------------------------------------------------------

output "dashboard_urls" {
  description = "Map of dashboard key to absolute Grafana URL (only populated when provisioning is enabled)."
  value = local.grafana_provisioning_enabled ? {
    for k, _ in local.dashboards :
    k => "${var.grafana_url}/d/${grafana_dashboard.this[k].uid}"
  } : {}
}
