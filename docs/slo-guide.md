# SLO Authoring Guide

This guide explains how to add a new Service Level Objective (SLO) to the
observability stack. Each SLO ships as a pair of files: a Prometheus rules
YAML in `alerts/` plus a small Terraform stanza in `terraform/slo-alerts.tf`.

The stack already ships two SLOs as worked examples:

- **Availability** (`alerts/slo-availability.yaml`) — 99.9% of HTTP requests
  must succeed (status not in `5xx`) over a rolling 30-day window.
- **Latency** (`alerts/slo-latency.yaml`) — 99% of HTTP requests must
  complete in under 300ms (p95) over a rolling 30-day window.

## 1. Pick the SLI

A Service Level Indicator (SLI) is a number you can compute every minute
from telemetry that is already being scraped. Good SLIs:

- Availability: `(good_requests / total_requests)` derived from a counter.
- Latency: `(fast_requests / total_requests)` derived from a histogram bucket.
- Throughput: `(processed_messages / scheduled_messages)` for batch systems.

Bad SLIs: synthetic probes that only run hourly, sampled traces, dashboards
that average over arbitrary windows.

## 2. Pick the SLO target

Decide an objective number (e.g. 99.9%) and the window over which it is
measured (we use 30-day rolling windows everywhere). The error budget is
`1 - target` — for 99.9% that's 0.1% (about 43 minutes per month).

## 3. Create the recording rules

Pre-computed recording rules keep alert evaluation cheap and ensure all
windows agree on the underlying ratio. For each window an alert reads,
add a recording rule first.

```yaml
- record: job:slo_<name>:ratio_rate_1h
  expr: |
    sum by (job) (rate(<bad_event_metric>[1h]))
      /
    sum by (job) (rate(<total_event_metric>[1h]))
```

Conventional naming: `<level>:<slo>:<measurement>_<window>`. Sticking to
this convention keeps Grafana row builders simple.

## 4. Create the burn-rate alerts

Use the multi-window, multi-burn-rate pattern (Google SRE Workbook ch. 5).
For a 99.9% target your thresholds become:

| Tier       | Burn  | Long window | Short confirm | Severity | Notification |
|------------|------:|------------:|--------------:|----------|--------------|
| Fast burn  | 14.4x | 1h          | 5m            | critical | page         |
| Medium     | 6x    | 6h          | 30m           | critical | page         |
| Slow burn  | 3x    | 1d          | 1h            | warning  | ticket       |
| Trend      | 1x    | 3d          | 6h            | warning  | ticket       |

Threshold = `burn_rate * (1 - SLO_target)`. For 99.9% this is `burn_rate * 0.001`.

Required alert labels: `severity` (`critical` or `warning`), `slo` (a short
identifier), and `team` (owner). The alert manager config in
`terraform/slo-alerts.tf` routes on `severity`, so these are not optional.

Required annotations: `summary`, `description`, and `runbook_url`. The
runbook script (`scripts/inject-runbook-links.py`) will fail CI if any
alert is missing one of these.

## 5. Wire the new YAML into Terraform

Open `terraform/slo-alerts.tf` and add a new
`aws_prometheus_rule_group_namespace` resource. Copy the block for an
existing SLO and edit the `name` and YAML path. Validation will run
automatically — broken YAML cannot reach AMP.

```hcl
resource "aws_prometheus_rule_group_namespace" "slo_throughput" {
  name         = "${local.name_prefix}-slo-throughput"
  workspace_id = aws_prometheus_workspace.this.id
  data         = file("${path.module}/../alerts/slo-throughput.yaml")
  depends_on   = [data.external.validate_slo_yaml]
}
```

Don't forget to add the new file path to the `for_each` list inside the
`data "external" "validate_slo_yaml"` block — that is what triggers the
plan-time YAML check.

## 6. Test the rules locally

```
make test-rules        # runs promtool check rules + promtool test rules
make plan              # terraform plan to confirm AMP namespace creation
```

`promtool test rules` against a fixture file is the cheapest way to catch
threshold typos. Add at least one passing and one failing input.

## 7. Verify after rollout

After `terraform apply`:

1. AMP console -> Rule groups -> confirm the new namespace appears with
   the expected number of rules.
2. Grafana -> Alerts -> the new alerts should show as `Inactive` (no
   firing samples yet).
3. Force a synthetic burn (e.g. blackbox exporter returning 500s) and
   confirm the fast-burn alert paged within ~1 minute.

## Reference

- Google SRE Workbook, ch. 5: <https://sre.google/workbook/alerting-on-slos/>
- AMP rule groups: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-Ruler.html>
- AMP alert manager: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-alert-manager.html>
