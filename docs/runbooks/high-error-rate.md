# Runbook: HighErrorRate

**Severity:** critical
**Composite alarm:** `obs-<env>-composite-HighErrorRate`
**Notification channel:** SNS topic `obs-<env>-alerts-high` -> Slack `#alerts-prod`
**On-call action:** Immediate page. Investigate within 5 minutes.

## What this alert means

One or more services tagged in `terraform/composite-alarms.tf`
(`monitored_services` variable) is returning HTTP 5xx responses above the
configured threshold. The composite alarm OR's together the per-service
5xx alarms, so the offending service is identified by the *child alarm
name* (e.g. `obs-prod-api-5xx-rate`).

Equivalent SLO alerts (Prometheus side):

  * `SLOAvailabilityFastBurn` - 14.4x burn over 1h (page)
  * `SLOAvailabilityMediumBurn` - 6x burn over 6h (page)
  * `SLOAvailabilitySlowBurn` - 3x burn over 1d (ticket)

If you arrived here from a Grafana panel, the panel link injection done by
`scripts/inject-runbook-links.py` ensures all of these alerts point to this
page.

## Quick triage (60 seconds)

1. Open the **Workload Golden Signals** Grafana dashboard.
   Filter to the offending `job` (from the alert label).
2. Read the RED panels:
   - **R**ate - any sudden spike or drop? Spike = retry storm. Drop = upstream death.
   - **E**rrors - which status codes? 502/503 = bad gateway, 500 = app, 504 = timeout.
   - **D**uration - latency spike at the same time? Likely upstream slow.
3. Open the AWS console -> Application Load Balancer -> Target group ->
   Monitoring tab. Confirm unhealthy hosts count.
4. Run:
   ```
   kubectl get pods -n <namespace> -l app=<service> -o wide
   kubectl describe pod <pod> -n <namespace>      # for any CrashLoopBackOff
   kubectl logs <pod> -n <namespace> --tail=200   # last 200 log lines
   ```

## Common root causes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| All pods CrashLoopBackOff right after a deploy | bad release | rollback (`kubectl rollout undo deployment/<svc>`) |
| Some pods 5xx, others 200 | bad pod or zonal failure | cordon the bad node, let HPA/PDB reschedule |
| 502 only, increasing | upstream (DB / 3rd party) dead or slow | check downstream dashboards |
| 504 spike | latency upstream > ALB idle timeout | bump timeout if legit, or check downstream |
| 5xx + 4xx both rising | dependency outage | check Status pages, GuardDuty |
| Spike after a feature flag flip | bad rollout | flip the flag back |

## Mitigation

In order of preference:

1. **Rollback** the last deploy. The CodePipeline auto-rollback
   (`terraform/target-account/codedeploy-rollback.tf`) should already be
   triggered if a CodeDeploy alarm was attached - but a manual rollback
   removes ambiguity.

2. **Scale up.** If the cause is load (not bad code), bump the HPA:
   ```
   kubectl scale deployment/<svc> --replicas=<n> -n <namespace>
   ```

3. **Drain the bad node.** If the failure is zonal or on one node:
   ```
   kubectl cordon <node>
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
   ```

4. **Block the load.** If we're under attack, the WAF rate-limit rules in
   `aws-edge-security-platform/terraform/modules/waf/rate_limit.tf` can be
   tightened. Coordinate with security before changing rules in production.

## When to call it resolved

- Composite alarm goes to OK state for 3 consecutive evaluation periods (3 minutes).
- Slack message reflects the OK state.
- 5xx rate panel in Grafana is back to baseline (use the dashed reference line).

## Post-incident actions

1. File a postmortem ticket if customer-visible for more than 5 minutes.
2. Capture the **last good commit SHA** before rollback - reference it in the postmortem.
3. If a new failure mode, add a child alarm to `terraform/composite-alarms.tf`
   so this composite catches it next time.
4. Update this runbook if any of the above steps were misleading.

## Related dashboards and links

- Workload Golden Signals dashboard (`dashboards/workload-golden-signals.json`)
- EKS Cluster dashboard (`dashboards/eks-cluster.json`)
- Composite alarm in console: `aws cloudwatch describe-alarms --alarm-names obs-prod-composite-HighErrorRate`
- Slack notifier source: `terraform/sns.tf`
