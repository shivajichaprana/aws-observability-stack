# Runbook: HighLatency

**Severity:** warning (paged via SNS `alerts_low` topic)
**Composite alarm:** `obs-<env>-composite-HighLatency`
**Notification channel:** SNS topic `obs-<env>-alerts-low` -> Slack `#alerts-warn`
**On-call action:** Triage within 15 minutes during business hours, next business day otherwise.

## What this alert means

One or more services in `monitored_services` (see
`terraform/composite-alarms.tf`) has p95 ALB target response time above the
configured threshold (default 500 ms) for 3 of the last 5 minutes.

Equivalent SLO alerts (Prometheus side):

  * `SLOLatencyFastBurn`
  * `SLOLatencyMediumBurn`
  * `SLOLatencySlowBurn`

Latency *alone* is not paged at critical severity because increased latency
without error budget burn often does not affect users in a material way.
When latency *and* error rate are both elevated, expect a separate
`HighErrorRate` page to take priority.

## Quick triage (60 seconds)

1. Open the **Workload Golden Signals** dashboard. Filter to the alerting
   job. Look at the p50, p95 and p99 latency panels side by side:
   - **p50 stable, p95+p99 high** -> tail latency. Likely GC, lock
     contention, slow-path code, or a long-tail of slow requests from a
     specific client.
   - **All percentiles up evenly** -> general slowness. Likely upstream
     dependency or saturated resource.
2. Open the **RDS** dashboard for any RDS instance the service uses.
   - CPU saturation
   - DB connections at max
   - Replica lag
   - Slow query log entries in the last 15 minutes
3. Check the **EKS Cluster** dashboard for node CPU and memory pressure.
   If a NodePressure composite is also firing, treat that one first.

## Common root causes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| p99 climbs, p50 flat | GC pauses, lock contention | profile the service; check JVM/Go heap metrics |
| All percentiles climb together | DB or downstream service slow | scale up the dependency or shed load |
| Latency spikes every N minutes | scheduled job stealing CPU | move the job to a separate node pool |
| Spike right after a deploy | new code path is slow | rollback, then profile |
| Daily latency drift | dataset growth, missing index | EXPLAIN the slow queries, add index |
| Spike on Spot interruption | nodes draining | check Karpenter logs, increase On-Demand fallback |
| Network latency between AZs | misconfigured topology spread | review `topologySpreadConstraints` |

## Mitigation

In order of preference:

1. **Identify and shed the bad traffic.** If a single client is causing
   tail latency (often visible as a single User-Agent in WAF logs), add a
   rate-limit rule in `aws-edge-security-platform`.

2. **Scale horizontally.** Bump the HPA target replicas if CPU is the
   bottleneck. Watch for connection-pool saturation: more pods = more DB
   connections.

3. **Switch traffic away.** If the latency is regional, the Route 53
   failover record in `aws-backup-dr/terraform/route53-failover.tf` can be
   forced to the DR region.

4. **Optimise the downstream.** Most latency alerts trace back to a slow
   dependency. Common quick wins:
   - Bump RDS instance size temporarily.
   - Add a read replica.
   - Add or warm a cache (ElastiCache, in-memory).

## When to call it resolved

- Composite alarm OK for 3 evaluation periods.
- p95 latency at or below the SLO target on the Golden Signals dashboard.
- No queued alert flapping (`X-Ray` traces also back to normal duration).

## Post-incident actions

1. File a ticket if the SLO error budget consumed > 10% during the incident.
2. Capture the slow trace IDs from X-Ray for the postmortem.
3. If the cause is a slow query, add the query to the slow-query inventory.
4. Consider adding a new child alarm for the specific symptom (e.g. DB
   connection saturation) so the next occurrence pages earlier.

## Related dashboards and links

- Workload Golden Signals (`dashboards/workload-golden-signals.json`)
- RDS dashboard (`dashboards/rds.json`)
- Lambda dashboard (`dashboards/lambda.json`)
- AWS X-Ray Service Map for the alerting service
- SLO definition: `alerts/slo-latency.yaml`
