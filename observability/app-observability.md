<!--
  Synced from databricks-fieldkit on 2026-07-14
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

## Prerequisites

- Workspace in a supported region — check current availability, since regional rollout expands over time
- `CAN MANAGE` on the target UC catalog/schema, plus `CREATE TABLE` on the schema (the platform creates the three `otel_*` tables automatically)
- Target tables must be managed Delta tables in the same region as the workspace
- Enable predictive optimization on the telemetry tables for steady-state query performance

## Runtime Environment

App telemetry runs inside the standard Databricks Apps runtime:

| Property | Value |
|---|---|
| OS | Ubuntu 22.04 LTS |
| Python | 3.11 (dedicated venv; `uv` apps can specify a different version) |
| Node.js | 22.16 (no pre-installed libraries — declare all dependencies in `package.json`) |
| Compute | 2 vCPUs, 6 GB memory by default (configurable) |

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

## Security Monitoring via System Tables

Pair app-level telemetry with `system.access.audit` for governance and security review workflows.

### App permission changes

```sql
WITH permission_changes AS (
  SELECT
    event_date,
    workspace_id,
    request_params.request_object_id AS app_name,
    user_identity.email AS modified_by,
    explode(from_json(
      request_params.access_control_list,
      'array<struct<user_name:string,group_name:string,permission_level:string>>'
    )) AS permission
  FROM system.access.audit
  WHERE action_name = 'changeAppsAcl'
    AND event_date >= current_date() - 30
)
SELECT event_date, app_name, modified_by,
  permission.user_name, permission.group_name, permission.permission_level
FROM permission_changes
ORDER BY event_date DESC;
```

### Apps configured with user API scopes (OBO)

```sql
SELECT
  event_date,
  get_json_object(request_params.app, '$.name') AS app_name,
  user_identity.email AS creator_email,
  get_json_object(request_params.app, '$.user_api_scopes') AS user_api_scopes
FROM system.access.audit
WHERE action_name IN ('createApp', 'updateApp')
  AND get_json_object(request_params.app, '$.user_api_scopes') IS NOT NULL
  AND event_date >= current_date() - INTERVAL 30 DAYS;
```

### On-behalf-of action volume by app

```sql
WITH obo_events AS (
  SELECT
    event_date, workspace_id, audit_level,
    identity_metadata.acting_resource AS app_id,
    user_identity.email AS user_email,
    service_name, action_name
  FROM system.access.audit
  WHERE event_date >= current_date() - 30
    AND identity_metadata.acting_resource IS NOT NULL
)
SELECT event_date, app_id, user_email, service_name, action_name,
  audit_level, COUNT(*) AS event_count
FROM obo_events
GROUP BY event_date, app_id, user_email, service_name, action_name, audit_level
ORDER BY event_date DESC;
```

---

## Cost Monitoring

```sql
SELECT
  us.usage_date,
  us.usage_metadata.app_id,
  us.usage_metadata.app_name,
  SUM(us.usage_quantity) AS dbus,
  SUM(us.usage_quantity * lp.pricing.effective_list.default) AS dollars
FROM system.billing.usage us
LEFT JOIN system.billing.list_prices lp
  ON lp.sku_name = us.sku_name
  AND us.usage_start_time BETWEEN lp.price_start_time AND COALESCE(lp.price_end_time, NOW())
WHERE billing_origin_product = 'APPS'
  AND us.usage_unit = 'DBU'
  AND us.usage_date >= DATE_SUB(NOW(), 30)
GROUP BY ALL;
```

Budget policies apply to app cost tracking the same way they do for other billed usage.

---

## App Insights

The **Insights** tab on the app details page provides two additional views without any custom instrumentation:

- **Viewer tracking** — which users accessed the app and when, aligned to OAuth refresh cycles
- **Uptime and health** — platform availability (service health) and application availability (request serving)

---

## Limits to Plan Around

| Limit | Value |
|---|---|
| Max log line size | 1 MB |
| Max record size | 10 MB (10,485,760 bytes) |
| Max request size | 30 MB |
| Throughput per stream | 100 MB/s (benchmarked at 1 KB messages) |
| Throughput per target table | 10 GB/s |
| Records per second per stream | 15,000 |
| Delivery semantics | At-least-once |
| Table type | Managed Delta only, same region |
| Schema | Treat target tables as immutable — design names up front |
| Compliance workspaces | Not currently available on FedRAMP, HIPAA, or PCI-DSS workspaces |

**Latency**: time to durability P50 ≤ 200ms / P95 ≤ 500ms; time to table P50 ≤ 5s / P95 ≤ 30s.

> Enable predictive optimization on the telemetry tables for better query performance under steady write load — Zerobus writes are async relative to clustering.

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
