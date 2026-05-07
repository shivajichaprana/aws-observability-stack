# Architecture (initial sketch)

A polished architecture document with a Mermaid diagram lands on Day 48. This
file captures the high-level intent so the rest of the codebase has something to
anchor against.

## Pillars

```
metrics  ──►  OTel Collector ──►  Amazon Managed Prometheus
logs     ──►  Fluent Bit      ──►  CloudWatch Logs
traces   ──►  OTel Collector ──►  AWS X-Ray
                                   │
                                   ▼
                            Amazon Managed Grafana
                                   │
                                   ▼
                              SNS → Slack/email
```

## Why managed services

- **AMP** scales automatically and removes the need to run a Prometheus HA pair.
- **AMG** ships with AWS SSO, IAM Identity Center, audit logging, and built-in
  data sources for AMP, CloudWatch, X-Ray, and Athena.
- **OTel Collector** decouples application instrumentation from backend choice
  — apps emit OTLP and we pick where it goes server-side.

## Account layout

This project provisions resources into **one** AWS account (the observability
account). Workload accounts forward telemetry through the OTel Collector, with
cross-account Grafana access governed through IAM Identity Center groups.

## SLO methodology

Alerts use Google's multi-window, multi-burn-rate approach: a fast 1h window
catches catastrophic failures, a 6h window catches steady degradation, and a 1d
window catches slow burns. See `docs/slo-guide.md` (lands Day 46).
