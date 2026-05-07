# Runbook: DeadMansSwitch

**Severity:** N/A (sentinel)
**On-call action:** Investigate alerting pipeline if this alert is **NOT** firing.

## What this alert means

`DeadMansSwitch` is a synthetic alert that always evaluates to `true`. The
absence of this alert in the alerting backend means the AMP rule evaluator,
SNS topic, or downstream notifier is broken — *not* that everything is fine.

## Verifying the pipeline

1. Confirm the alert is currently active in Grafana → Alerting → Active.
2. Confirm the alert rule exists in AMP:
   ```
   aws amp list-rule-groups-namespaces --workspace-id <WORKSPACE_ID>
   ```
3. Confirm the SNS topic has at least one subscription:
   ```
   aws sns list-subscriptions-by-topic --topic-arn <TOPIC_ARN>
   ```

## When it is NOT firing

- Check AMP workspace status → should be `ACTIVE`.
- Check the rule-group namespace; a malformed YAML upload disables the entire
  namespace silently.
- Check IAM permissions on the AMG workspace role — `aps:QueryMetrics` is
  required for the rule evaluator.

## Related links

- AMP workspace: see `terraform output amp_workspace_id`
- AMG workspace: see `terraform output amg_workspace_endpoint`
