###############################################################################
# slo-alerts.tf
#
# Loads the multi-window, multi-burn-rate SLO alert YAMLs from `alerts/`
# into the Amazon Managed Prometheus workspace using
# `aws_prometheus_rule_group_namespace`. Each namespace is a logical
# bucket within the workspace; we keep availability and latency in
# separate namespaces so they can be enabled/disabled and version-tagged
# independently.
#
# The alert YAMLs themselves live in `alerts/slo-availability.yaml` and
# `alerts/slo-latency.yaml`. Editing those files and running
# `terraform apply` is enough to update the rules in AMP.
#
# Routing of these alerts to SNS / Slack lives in `sns.tf`, which adds an
# `aws_prometheus_alert_manager_definition` resource pointing at the
# topics created there.
###############################################################################

# Validate every YAML file at plan-time so a typo in a Prometheus expression
# fails fast before reaching AMP. AMP returns a 400 with a sometimes-cryptic
# message if the YAML is malformed, so the up-front validation is worth it.
data "external" "validate_slo_yaml" {
  for_each = toset([
    "${path.module}/../alerts/slo-availability.yaml",
    "${path.module}/../alerts/slo-latency.yaml",
  ])

  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    f="${each.value}"
    if [ ! -f "$f" ]; then
      echo "{\"ok\":\"false\",\"reason\":\"missing_file\"}"
      exit 1
    fi
    # Best-effort YAML validation. promtool may not be on PATH in CI;
    # fall back to a simple syntactic check via python.
    if command -v promtool >/dev/null 2>&1; then
      promtool check rules "$f" >/dev/null 2>&1 \
        && echo "{\"ok\":\"true\"}" \
        || { echo "{\"ok\":\"false\",\"reason\":\"promtool_failed\"}"; exit 1; }
    else
      python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" >/dev/null 2>&1 \
        && echo "{\"ok\":\"true\"}" \
        || { echo "{\"ok\":\"false\",\"reason\":\"yaml_invalid\"}"; exit 1; }
    fi
  EOT
  ]
}

resource "aws_prometheus_rule_group_namespace" "slo_availability" {
  name         = "${local.name_prefix}-slo-availability"
  workspace_id = aws_prometheus_workspace.this.id
  data         = file("${path.module}/../alerts/slo-availability.yaml")

  # depends_on forces the validation data source to run first so a broken
  # YAML never reaches the AMP API.
  depends_on = [
    data.external.validate_slo_yaml,
  ]
}

resource "aws_prometheus_rule_group_namespace" "slo_latency" {
  name         = "${local.name_prefix}-slo-latency"
  workspace_id = aws_prometheus_workspace.this.id
  data         = file("${path.module}/../alerts/slo-latency.yaml")

  depends_on = [
    data.external.validate_slo_yaml,
  ]
}

# Outputs that are useful in CI to confirm the rules landed.
output "slo_availability_namespace_arn" {
  description = "ARN of the AMP rule group namespace holding availability SLO alerts."
  value       = aws_prometheus_rule_group_namespace.slo_availability.arn
}

output "slo_latency_namespace_arn" {
  description = "ARN of the AMP rule group namespace holding latency SLO alerts."
  value       = aws_prometheus_rule_group_namespace.slo_latency.arn
}
