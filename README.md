# aws-observability-stack

Production-grade AWS observability platform built on managed services: **Amazon Managed
Prometheus (AMP)** for metrics, **Amazon Managed Grafana (AMG)** for visualization,
**AWS X-Ray** for distributed tracing, and the **OpenTelemetry Collector** running on
EKS as the unified telemetry pipeline. Includes opinionated defaults for SLO-based
alerting, runbook automation, and ready-to-import Grafana dashboards.

## Why this exists

Most teams running on AWS end up with a fragmented observability stack —
self-hosted Prometheus running out of space, Grafana installed somewhere with no SSO,
CloudWatch metrics nobody looks at, and X-Ray traces that never make it into the same
pane of glass. This project wires up the **managed** AWS observability primitives in a
way that:

- Removes the operational toil of running Prometheus and Grafana yourself.
- Uses the OpenTelemetry Collector as the single ingestion point, so your apps emit
  OTLP and don't care where data eventually lands.
- Ships with SLO burn-rate alerts and a small library of dashboards that follow the
  RED method (Rate, Errors, Duration) and Google's golden signals.
- Annotates every alert with a runbook URL.

## Component overview

| Component | Purpose | Provisioned by |
|-----------|---------|----------------|
| Amazon Managed Prometheus | Long-term metric storage, PromQL query API | `terraform/amp.tf` |
| Amazon Managed Grafana | Dashboards, alerting UI | `terraform/amg.tf` |
| OpenTelemetry Collector | Cluster-wide ingestion (OTLP → AMP / X-Ray) | `otel/` |
| AWS X-Ray | Distributed traces | OTel `awsxray` exporter |
| SNS + Slack Lambda | Alert delivery | `terraform/sns.tf` (Day 46) |
| QuickSight / Athena | Long-term ad-hoc analytics (optional) | future |

## Repository layout

```
aws-observability-stack/
├── terraform/        # AMP, AMG, IRSA, alerts, SNS, dashboards-as-code
├── otel/             # OpenTelemetry Collector manifests + config
├── dashboards/       # Grafana dashboard JSON exports
├── alerts/           # PromQL alert rule groups (SLO + infra)
├── scripts/          # Operational helpers (runbook injection, etc.)
├── docs/             # Architecture, runbooks, SLO authoring guide
└── .github/workflows # Terraform + Promtool + dashboard-schema CI
```

## Quick start (preview)

```bash
make init                            # terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply     # provisions AMP + AMG
kubectl apply -k otel/               # deploys the Collector to EKS
```

A full bootstrap walkthrough lands in `docs/quickstart.md` on Day 48.

## Status

Project under active development as part of a 90-day GitHub streak. Day-by-day
progress is captured in commit history; a polished README, end-to-end architecture
diagram, and `v1.0.0` release land on **Saturday May 16**.

## License

[MIT](LICENSE)
