# Runbook: NodePressure

**Severity:** critical
**Composite alarm:** `obs-<env>-composite-NodePressure`
**Notification channel:** SNS topic `obs-<env>-alerts-high` -> Slack `#alerts-prod`
**On-call action:** Immediate page. Risk of cascading workload eviction.

## What this alert means

The average node CPU utilisation across the EKS cluster is above 80% **or**
the average node memory utilisation is above 85%, sustained for 3 of the
last 5 minutes (Container Insights metrics, `ContainerInsights` namespace).

The composite is fed by two child alarms - one for CPU, one for memory -
so the **child alarm name** in the Slack message tells you which dimension
is hot.

Why two thresholds:

- **Memory pressure** is the more dangerous of the two. The kubelet starts
  evicting pods at `memory.available < eviction-hard` (default 100Mi). At
  that point you get involuntary `Pod has been killed for OOM` events,
  which usually means a customer-visible incident.
- **CPU pressure** rarely causes incidents on its own - workloads
  throttle but keep running - but sustained CPU pressure on a small
  cluster makes everything else (kubelet, kube-proxy, control-plane
  metrics) less responsive.

## Quick triage (60 seconds)

1. Open the **EKS Cluster** dashboard. Look at the per-node CPU/memory
   panel.
2. Identify the hot node(s):
   ```
   kubectl top nodes --sort-by=cpu
   kubectl top nodes --sort-by=memory
   ```
3. Identify the pod(s) consuming the resource on those nodes:
   ```
   kubectl top pods -A --sort-by=cpu | head -20
   kubectl top pods -A --sort-by=memory | head -20
   ```
4. Check Karpenter: is it provisioning more nodes already?
   ```
   kubectl get nodeclaim
   kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=200
   ```
5. Check EKS events for OOM:
   ```
   kubectl get events -A --field-selector reason=OOMKilling
   ```

## Common root causes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| One pod eating all RAM | memory leak | restart pod, scale horizontally, file bug |
| Sudden spike across all nodes | traffic surge | wait for Karpenter; if too slow, scale baseline NG manually |
| Memory climbs slowly over hours | GC tuning issue | profile heap; consider bumping memory request |
| Cluster has no spare capacity | bad bin-packing or stuck pods | drain a node, let scheduler rebin |
| Karpenter not scaling | misconfigured NodePool / EC2NodeClass | check `kubectl describe nodepool` |
| CPU pressure, memory fine | CPU-bound workload (image transcoding, ML inference) | use a CPU-optimised node pool |

## Mitigation

In order of preference:

1. **Let Karpenter handle it.** Healthy clusters should provision a new
   node within ~30 seconds of pending pods appearing. Verify:
   ```
   kubectl get pods -A --field-selector=status.phase=Pending
   ```
   If pods are pending and Karpenter isn't reacting, escalate to the
   platform team - usually an IAM, SQS, or NodePool config issue.

2. **Cordon and drain the worst-offending node** so workloads reschedule
   onto cooler ones:
   ```
   kubectl cordon <node>
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
   ```
   Be aware of PDBs - drain will block on services that don't have
   enough replicas.

3. **Scale the managed node group manually** (last resort, costs money):
   ```
   aws eks update-nodegroup-config \
     --cluster-name <cluster> \
     --nodegroup-name <ng> \
     --scaling-config minSize=4,maxSize=20,desiredSize=8
   ```

4. **Quarantine the noisy neighbour.** If one workload is consistently
   the cause, give it a dedicated NodePool with taints, or apply tighter
   resource limits.

## When to call it resolved

- Composite alarm OK for 5 evaluation periods.
- `kubectl top nodes` shows all nodes below 75% CPU and 75% memory.
- No pending pods.

## Post-incident actions

1. If pods were OOMKilled, capture pod names and times - they belong in
   the postmortem.
2. If Karpenter delays exceeded 60 seconds, file a ticket against the
   platform; check whether the AMI or instance-type-list is the bottleneck.
3. Review resource requests vs actual usage for the noisy workload. If
   the request is too low, the scheduler is over-packing the node.
4. Consider whether a Vertical Pod Autoscaler recommendation would have
   prevented this.

## Related dashboards and links

- EKS Cluster dashboard (`dashboards/eks-cluster.json`)
- Karpenter logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`
- AWS Container Insights:
  `https://console.aws.amazon.com/cloudwatch/home#container-insights:`
- Composite alarm:
  `aws cloudwatch describe-alarms --alarm-names obs-prod-composite-NodePressure`
