# OpenTelemetry Setup Guide

This guide walks through onboarding a workload service to the
`aws-observability-stack`. It covers Collector deployment, application
instrumentation, and validation.

The Collector ships as **two** components — a DaemonSet (node-local
receiver) and a Deployment (gateway). Workloads emit OTLP to
`localhost:4317` on their own node; the DaemonSet forwards to the gateway,
which batches and exports to AMP, X-Ray, and CloudWatch Logs.

## Topology

```
+--------------+   localhost:4317    +-------------------+   headless svc   +-----------------+
| app pod      | -----------------> | otel-collector ds | ---------------> | otel-collector  |
| (OTLP/gRPC)  |                    | (DaemonSet)       |                  | gateway (Deploy)|
+--------------+                    +-------------------+                  +--------+--------+
                                                                                    |
                                  +---------------+---------------+-----------------+
                                  | remote_write  | awsxray       | awscloudwatchlogs
                                  v               v               v
                              +-------+      +---------+      +----------+
                              |  AMP  |      |  X-Ray  |      |   CW     |
                              +-------+      +---------+      +----------+
```

## Prerequisites

- EKS cluster with an IRSA-capable OIDC provider.
- AMP workspace and IAM role (`otel-collector-irsa`) already provisioned —
  this happens automatically when you `make apply` the Terraform.
- `kubectl` configured against the target cluster, `helm` ≥ 3.12.

## Step 1 — Deploy the Collector

```bash
kubectl create namespace observability
kubectl apply -f otel/configmap.yaml
kubectl apply -f otel/collector-daemonset.yaml
kubectl apply -f otel/collector-deployment.yaml

kubectl -n observability rollout status ds/otel-collector
kubectl -n observability rollout status deploy/otel-collector-gateway
```

The Collector ServiceAccount in `observability` has the IRSA annotation
`eks.amazonaws.com/role-arn` pointing at the Terraform-managed IAM role with
the `aps:RemoteWrite*`, `xray:PutTraceSegments`, and `logs:PutLogEvents`
permissions.

## Step 2 — Instrument the application

### Language SDKs

For any language, the pattern is the same: install the OTel SDK + OTLP/gRPC
exporter, configure it via environment variables, and let the auto-instrumentations
take over.

Set these env vars on the workload Pod (works for every language):

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: my-service
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: deployment.environment=$(ENVIRONMENT),service.namespace=$(K8S_NAMESPACE)
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://$(HOST_IP):4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: grpc
  - name: OTEL_TRACES_SAMPLER
    value: parentbased_traceidratio
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"        # 10% trace sampling — tune per service
  - name: OTEL_METRIC_EXPORT_INTERVAL
    value: "30000"      # 30s — match Prometheus scrape interval
  - name: HOST_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: K8S_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
```

`HOST_IP` is the trick that routes telemetry to the DaemonSet on the same
node — no service DNS needed, no per-pod target lookup.

### Per-language quickstarts

#### Python (Flask / FastAPI / Django)

```bash
pip install \
  opentelemetry-distro \
  opentelemetry-exporter-otlp \
  opentelemetry-instrumentation
opentelemetry-bootstrap --action=install
```

Then prefix your process launch with `opentelemetry-instrument`:

```dockerfile
CMD ["opentelemetry-instrument", "gunicorn", "myapp.wsgi:application"]
```

#### Node.js

```bash
npm install \
  @opentelemetry/api \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc
```

Load auto-instrumentations via `--require`:

```dockerfile
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "server.js"]
```

#### Java

Add the OTel Java agent as an init container or bake it into your image, then
add a `-javaagent:/otel/opentelemetry-javaagent.jar` JVM flag.

#### Go

There is no auto-instrumentation for Go (the runtime forbids it). Use the
manual SDK:

```go
exp, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithInsecure(),
    otlptracegrpc.WithEndpoint(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
)
tp := sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(exp),
    sdktrace.WithResource(resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceName(os.Getenv("OTEL_SERVICE_NAME")),
    )),
)
otel.SetTracerProvider(tp)
```

### Application metrics

Most language SDKs expose request-level metrics automatically via the OTel
HTTP / gRPC instrumentations. For custom metrics, use the OTel API:

```python
from opentelemetry import metrics

meter = metrics.get_meter("my-service")
orders_processed = meter.create_counter(
    "orders.processed",
    description="Total orders processed",
)

orders_processed.add(1, {"status": "success"})
```

The Collector translates OTel metrics into Prometheus format via the
`prometheusremotewrite` exporter, so they appear in AMP with the
`otel_scope_name` label set to your meter name.

## Step 3 — Verify

### Metrics

```bash
curl -H "Authorization: AWS4-HMAC-SHA256 ..." \
  "$AMP_QUERY_URL/api/v1/query?query=up{job=\"otel-collector\"}"
```

In Grafana: explore → AMP data source → `up{job="otel-collector"}` →
expect 1 per Collector pod.

### Traces

In Grafana: explore → X-Ray data source → service map → your service should
appear within ~60 seconds of receiving its first request.

### Logs

If your app writes to stdout and you have Fluent Bit or the Collector
`filelog` receiver enabled, logs appear in CloudWatch under
`/aws/eks/<cluster>/application`.

## Tuning

### Sampling

Start at 10% (`OTEL_TRACES_SAMPLER_ARG=0.1`). Increase for low-traffic
services (1.0 is fine under ~100 req/s), decrease for hot paths (`0.01` at
> 10k req/s).

### Batching

The gateway Collector batches by default (`send_batch_size: 8192`,
`timeout: 200ms`). On a small cluster you can leave these alone; on a busy
cluster, raise `send_batch_size` to 16384 to amortize remote_write overhead.

### Memory limits

The Collector ships with a `memory_limiter` processor (configured in
`otel/configmap.yaml`) that drops data before the pod gets OOM-killed.
The defaults (limit 80%, spike 25%) are sensible for the bundled
DaemonSet resource request of `256Mi`. If you bump the request, bump the
limiter accordingly.

## Troubleshooting

| Symptom                                  | Likely cause                                  | Fix                                                                 |
|------------------------------------------|-----------------------------------------------|---------------------------------------------------------------------|
| App logs `connection refused on :4317`   | DaemonSet not running on that node            | `kubectl -n observability get pods -o wide` — check node selectors  |
| Metrics arrive in AMP with no labels     | Missing `OTEL_RESOURCE_ATTRIBUTES`            | Set service.name + deployment.environment env vars                  |
| Traces show in X-Ray but no service map  | Service uses only `client` spans              | Ensure server spans are emitted (auto-instrumentation usually does) |
| 403 from AMP remote_write                | IRSA role missing `aps:RemoteWrite*`          | Re-apply Terraform, verify ServiceAccount annotation                |
| Collector OOMs                           | `memory_limiter` not catching spikes          | Lower `limit_percentage` from 80 → 60 in configmap                  |
| High Collector CPU                       | Batch interval too short, too many small RPCs | Raise `send_batch_size`, raise `timeout`                            |

## Going further

- Add custom processors to the Collector pipeline — e.g., `tail_sampling`
  for trace sampling decisions based on response status.
- Federate to a second region by adding a second `prometheusremotewrite`
  exporter pointing at a different AMP workspace.
- Wire dashboards as code — see `dashboards/*.json` and `terraform/dashboards.tf`.
