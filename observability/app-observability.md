<!--
  Synced from databricks-fieldkit on 2026-04-27
  Sources: apps/observability.md
  Public docs grounding:
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/observability
    - https://docs.databricks.com/aws/en/dev-tools/databricks-apps/
  This file is auto-prepared and human-reviewed before publish.
-->

# App Observability — OpenTelemetry to UC Delta

> **TL;DR**: Databricks Apps emit OpenTelemetry **logs, traces, and metrics** to Unity Catalog Delta tables. System logs (auth events, request envelope) are captured automatically. Custom traces and metrics require wrapping the app command with `opentelemetry-instrument` and adding the relevant instrumentation packages. Three tables (`<prefix>_otel_logs`, `<prefix>_otel_spans`, `<prefix>_otel_metrics`) land in UC and join cleanly with MLflow Tracing on `trace_id`. This is the right surface for **app-level** signals (HTTP latency, request volume, login events); pair it with MLflow Tracing for agent-level signals.

---

## App Telemetry vs MLflow Tracing vs Endpoint Telemetry

| Surface | Captures | Granularity |
|---|---|---|
| **App telemetry** (this doc) | App-level HTTP requests, auth events, framework spans, system logs | Per-request, per-route |
| **MLflow Tracing** | LLM calls, tool invocations, retrieval steps inside the agent | Per-span inside a single agent turn |
| **Endpoint telemetry** | OTel signals from inside model code on a serving endpoint | Per-prediction, per-model worker |

A complete agent app instruments all three. Tags like `trace_id` and `session.id` propagated end-to-end let you join across them.

---

## Architecture

```
Databricks App (Streamlit · FastAPI · Dash · Flask · Node.js)
        │
        │ OTel protocol (auto + custom instrumentation)
        ▼
Zerobus Ingest Connector
        │  (at-least-once delivery)
        ▼
Unity Catalog Delta Tables
  ├── <prefix>_otel_logs      (auto: system + app logs)
  ├── <prefix>_otel_spans     (custom: framework + manual spans)
  └── <prefix>_otel_metrics   (custom: counters, histograms, gauges)
```

What lands automatically:
- **System logs** — startup, shutdown, configuration
- **Auth events** — user login, identity propagation events (`app.auth`)
- **Request envelope** — direct API request entries

What requires custom instrumentation:
- HTTP route latency by endpoint
- Custom business metrics (active sessions, tool invocations per minute)
- Manual spans inside request handlers

---

## Configure Telemetry on the App

1. Open the app's details page in the workspace
2. **App telemetry** section → **Add**
3. Select target UC catalog and schema; optionally set a prefix
4. Save and **redeploy the app** (required for telemetry to start flowing)

```sql
-- The three tables that get created
SHOW TABLES IN <catalog>.<schema> LIKE '%_otel_%';
-- <prefix>_otel_logs
-- <prefix>_otel_spans
-- <prefix>_otel_metrics
```

---

## Add Custom Instrumentation

Wrap the app command with `opentelemetry-instrument` and add framework-specific packages.

### Streamlit

```yaml
# app.yaml
command: ['opentelemetry-instrument', 'streamlit', 'run', 'app.py']
env:
  - name: OTEL_TRACES_SAMPLER
    value: 'always_on'
```

```
# requirements.txt
opentelemetry-distro
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-tornado
opentelemetry-instrumentation-system-metrics
```

### FastAPI

```yaml
command: ['opentelemetry-instrument', 'uvicorn', 'app:app',
          '--host', '0.0.0.0', '--port', '8000']
env:
  - name: OTEL_TRACES_SAMPLER
    value: 'always_on'
```

```
opentelemetry-distro
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-fastapi
```

### Dash / Flask

```yaml
command: ['opentelemetry-instrument', 'python', 'app.py']    # Dash
# or
command: ['opentelemetry-instrument', 'flask', '--app', 'app.py', 'run', '--no-reload']
env:
  - name: OTEL_TRACES_SAMPLER
    value: 'always_on'
```

```
opentelemetry-distro
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-flask
```

### Node.js

Create an `otel.js` bootstrap and load it on startup:

```json
{ "scripts": { "start": "node -r ./otel.js app.js" } }
```

Required packages: `@opentelemetry/sdk-node`, `@opentelemetry/auto-instrumentations-node`, `@opentelemetry/exporter-trace-otlp-proto`, `@opentelemetry/exporter-metrics-otlp-proto`.

---

## Querying Telemetry

Common columns: `time`, `service_name`, `trace_id`, `span_id`, `severity_text`, `body`, `attributes` (map).

### Recent errors

```sql
SELECT time, body, attributes
FROM <catalog>.<schema>.<prefix>_otel_logs
WHERE service_name = '<app-name>'
  AND severity_text = 'ERROR'
  AND time >= current_timestamp() - INTERVAL 1 HOUR
ORDER BY time DESC
LIMIT 100;
```

### Login activity for audit

```sql
SELECT
  time,
  attributes:["app.user"]::string  AS user_email,
  attributes:["app.auth.method"]::string AS method
FROM <catalog>.<schema>.<prefix>_otel_logs
WHERE attributes:["event.name"]::string = 'app.auth'
  AND time >= current_timestamp() - INTERVAL 7 DAYS
ORDER BY time DESC;
```

### Latency by route

```sql
SELECT
  attributes:["http.route"]::string AS route,
  approx_percentile(duration_ms, 0.50) AS p50_ms,
  approx_percentile(duration_ms, 0.95) AS p95_ms,
  approx_percentile(duration_ms, 0.99) AS p99_ms
FROM <catalog>.<schema>.<prefix>_otel_spans
WHERE service_name = '<app-name>'
  AND time >= current_timestamp() - INTERVAL 1 DAY
GROUP BY 1
ORDER BY p95_ms DESC;
```

---

## Joining With Other Planes

```sql
-- App span ↔ MLflow trace (same trace_id propagated)
SELECT
  s.attributes:["http.route"]::string AS route,
  s.duration_ms                       AS app_latency_ms,
  t.execution_time_ms                 AS agent_latency_ms,
  t.tags['caller']                    AS caller
FROM <catalog>.<schema>.<prefix>_otel_spans s
JOIN main.observability.archived_traces t
  ON s.trace_id = t.trace_id
WHERE s.time >= current_timestamp() - INTERVAL 1 DAY;
```

When the app's HTTP handler propagates the same `trace_id` into the agent's MLflow trace, this join gives one row per request with both the framework-level latency (HTTP entry to exit) and the agent-level latency (LLM + tool calls).

---

## Limits to Plan Around

| Limit | Value |
|---|---|
| Max log line size | 1 MB |
| Max record size | 10 MB |
| Max request size | 30 MB |
| Throughput before latency degrades | ~2,500 QPS |
| Delivery semantics | At-least-once |
| Table type | Managed Delta only, same region |
| Schema | Treat target tables as immutable — design names up front |

> Enable predictive optimization on the telemetry tables for better query performance under steady write load.

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| Any production Databricks App | Telemetry enabled at app creation; logs to a per-team UC schema |
| App-to-agent latency attribution | Propagate `trace_id` from the app handler into the MLflow trace |
| Auth audit | Query `<prefix>_otel_logs` for `event.name = 'app.auth'` |
| Per-route SLI dashboards | Custom OTel spans + AI/BI dashboard on `<prefix>_otel_spans` |
| High-QPS apps | Sample at the framework level (`OTEL_TRACES_SAMPLER`) to stay under 2,500 QPS |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Enabling telemetry but not redeploying | Telemetry config takes effect only on next deployment |
| Targeting a tablespace in a different region | Telemetry tables must live in the same region as the workspace |
| Renaming tables under the same prefix | Choose UC names up front; pick a new prefix when redesigning |
| Wrapping every command with `opentelemetry-instrument` indiscriminately | Add the right framework instrumentation package; otherwise spans are empty |
| Treating telemetry as a substitute for MLflow Tracing | Pair the two — app-level signals here, agent-level signals in MLflow |

---

## Related

- [`agent-tracing.md`](agent-tracing.md) — MLflow Tracing for agent-internal spans
- [`endpoint-telemetry.md`](endpoint-telemetry.md) — OTel from model serving endpoints
- [`audit-reference.md`](audit-reference.md) — Cross-plane audit story

---

## Public References

- [Databricks Apps observability](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/observability)
- [Databricks Apps overview](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/)
- [OpenTelemetry instrumentation packages (Python)](https://opentelemetry.io/docs/zero-code/python/)
