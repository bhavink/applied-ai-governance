<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: ai/model-serving.md, ai/endpoint-telemetry.md
  Public docs grounding: https://docs.databricks.com/aws/en/machine-learning/model-serving/
  This file is auto-prepared and human-reviewed before publish.
-->

# Model Serving Governance

> **TL;DR**: Model Serving endpoints are first-class governance objects. Each endpoint has UC-style permissions (`CAN_QUERY`, `CAN_MANAGE`, `IS_OWNER`), runs under a service principal that determines its data plane authority, can identity-pass to the caller via OBO, and can persist every request and response to UC Delta inference tables — plus structured logs, traces, and metrics for custom and agent endpoints. Treat endpoints the way you treat catalogs and tables: name them deterministically, grant by group, audit every call.

---

## Endpoint Surfaces and Their Governance Levers

| Surface | What runs | Primary governance levers |
|---|---|---|
| **Foundation Model API (FMAPI)** | Databricks-managed LLMs (Llama, DBRX, Mixtral, embedding models) | Account-level enablement; AI Gateway on the endpoint for rate limits and guardrails; usage audited via `system.serving.endpoint_usage` |
| **Provisioned Throughput** | Reserved capacity FMAPI endpoint | Same as FMAPI + per-endpoint capacity contract |
| **Custom Model** | Your registered MLflow model | Endpoint permissions, attached SP, inference tables, endpoint telemetry |
| **Agent endpoint** | An MLflow agent (deployed via `agents.deploy()`) | Endpoint permissions + identity propagation (`ModelServingUserCredentials`) + endpoint telemetry |
| **External Model** | Proxy to OpenAI, Anthropic, Bedrock, Vertex, etc. | Centralized auth, unified audit, AI Gateway controls in front of provider keys |

Endpoint telemetry (OTel logs/traces/metrics to UC) is available on custom model and agent serving endpoints. FMAPI endpoints rely on `system.serving.endpoint_usage` for usage auditing instead — see Audit Surfaces below.

All five surfaces share the governance primitives below.

---

## Permission Model

Endpoints have three permission levels, granted to users, groups, or service principals:

| Level | Capabilities |
|---|---|
| `CAN_VIEW` | See the endpoint exists and read its config |
| `CAN_QUERY` | Invoke the endpoint |
| `CAN_MANAGE` | Update config, change traffic splits, attach inference tables, delete |
| `IS_OWNER` | Full control plus permission management |

**Pattern**: grant `CAN_QUERY` to functional groups (e.g., `agents-readers`), `CAN_MANAGE` to a small platform team, and never assign `CAN_QUERY` to `all_users` for production endpoints.

---

## Identity Propagation

An endpoint runs under a service principal that determines what data the endpoint code can read. Two patterns:

### Pattern A — endpoint SP only (M2M)

The endpoint's attached SP is the only identity in the data plane. Every caller's UC reads happen as the SP. Use when the endpoint serves shared, non-personalized data (e.g., a recommendation model with public catalogs).

### Pattern B — caller identity passthrough (OBO via `ModelServingUserCredentials`)

When the endpoint is an agent, the agent code can call back into Databricks using the *caller's* identity rather than the endpoint SP's:

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.credentials_provider import ModelServingUserCredentials

w = WorkspaceClient(credentials_strategy=ModelServingUserCredentials())
# Genie, Vector Search, UC Function calls now run as the caller, not the endpoint SP.
```

Combined with UC row filters and column masks, this means each end user sees only the data they would see if they queried directly. The endpoint SP becomes the *capability ceiling*; UC grants on the caller become the *actual authorization*.

> **Use Pattern B for any agent** that surfaces personalized data. Pattern A is correct for shared/public knowledge agents.

---

## Traffic Splitting as a Governance Lever

Multi-entity endpoints with traffic configuration are not just for A/B experiments — they are how you do **canary releases** and **safe model upgrades** under governance.

```
Endpoint: prod-claims-classifier
  ├── version-7 (90% traffic)   ← stable, audited
  └── version-8 (10% traffic)   ← new model under canary
```

Pair traffic splits with inference tables: every request is logged with the `served_entity_id` of which version handled it. After a week of canary, query the table to confirm parity in error rate, latency, and (with scorers) output quality before flipping to 100%.

For multi-version endpoints behind AI Gateway, fallback routing handles 429 and 5XX transparently — a backup entity can serve fallback traffic when the primary errors.

---

## Inference Tables — Audit Logging

Every endpoint can auto-capture requests and responses to a UC Delta table.

```yaml
auto_capture_config:
  catalog_name: main
  schema_name: inference_logs
  table_name_prefix: claims_classifier
  enabled: true
```

Schema highlights:

| Column | Captures |
|---|---|
| `databricks_request_id` | Server-side request identifier |
| `request_time`, `execution_duration_ms` | Latency |
| `status_code` | HTTP status |
| `request`, `response` | Full payloads (within size limits) |
| `served_entity_id` | Which endpoint version handled the request |
| `requester` | User or SP that called the endpoint |

**Governance uses**:
- Compliance: every model decision tied to an identity and a model version
- Drift detection: compare input distributions over time
- Quality monitoring: score logged responses with MLflow scorers
- Incident response: replay traffic to a problem version

> **Treat inference tables as immutable audit logs.** Do not alter the schema, rename, or delete them after creation. Capture limits: 1 MiB per request/response on the serving endpoint path, up to ~1 hour delivery latency.

---

## Endpoint Telemetry — OTel to UC Delta

Custom model and agent serving endpoints can persist OpenTelemetry **logs**, **traces**, and **metrics** to UC Delta tables. This is complementary to inference tables: inference tables capture the request/response payload, while telemetry captures structured spans, metrics, and severity-tagged logs from inside the model or agent code. Foundation Model API endpoints use `system.serving.endpoint_usage` for usage auditing rather than this pipeline.

Three tables, one per signal:

```
<prefix>_otel_logs      ← Python logging output (automatic)
<prefix>_otel_spans     ← OTel TracerProvider spans (custom instrumentation)
<prefix>_otel_metrics   ← OTel MeterProvider metrics (custom instrumentation)
```

**Governance prerequisites**: a Unity Catalog-enabled workspace, plus `USE CATALOG` / `USE SCHEMA` / `CREATE TABLE` / `MODIFY` grants on the destination schema. Databricks creates the target tables automatically once the config is applied — no manual `CREATE TABLE` needed. Destination table names are fixed for the life of the config, so choose them deliberately as part of endpoint design. Availability varies by cloud and region — check the linked docs for current coverage before planning a rollout.

Configure on the endpoint:

```json
{
  "telemetry_config": {
    "table_names": {
      "logs_table":    "main.observability.endpoint_logs",
      "spans_table":   "main.observability.endpoint_spans",
      "metrics_table": "main.observability.endpoint_metrics"
    }
  }
}
```

Standard Python `logging` is captured automatically (default level `WARNING`; override in `load_context()` to capture `INFO`/`DEBUG`). Custom OTel spans and metrics require SDK instrumentation in the model code. Updating the telemetry config triggers an endpoint redeployment — schedule it during a maintenance window.

**Query pattern**:

```sql
-- Errors in the last hour
SELECT timestamp, severity_text, body, attributes
FROM main.observability.endpoint_logs
WHERE severity_text = 'ERROR'
  AND timestamp > current_timestamp() - INTERVAL 1 HOUR
ORDER BY timestamp DESC;
```

**Operating limits** — design retention and alerting around these:

| Limit | Value |
|---|---|
| Max log line | 1 MB |
| Max record | 10 MB |
| Max request | 30 MB |
| Sustained throughput | 2500 QPS before degradation |
| Delivery guarantee | At-least-once |
| Table type | Managed Delta only |
| Schema evolution | Design the schema up front — table schema is fixed once created |
| Typical latency | Logs land in the UC table within seconds of emission |

This latency profile is much tighter than inference tables (~1 hour), which makes telemetry the better fit for near-real-time debugging while inference tables remain the durable request/response audit trail.

---

## External Model Endpoints

Proxying external providers (OpenAI, Anthropic, Bedrock, Vertex) through a Databricks endpoint gives one governance surface for traffic that would otherwise bypass platform controls:

- **Single audit boundary** — every call lands in `system.serving.endpoint_usage` regardless of which provider served it
- **Provider keys stay in Databricks Secrets** — application code never holds raw provider keys
- **Unified rate limits and guardrails** — AI Gateway controls apply equally to internal FMAPI and external providers
- **Provider switching without app changes** — swap the served entity; clients keep calling the same endpoint name

Pair external model endpoints with **UC Service Credentials** when the provider supports IAM-based auth (e.g., AWS Bedrock with an IAM role) — credentials never leave UC.

---

## Audit Surfaces

| What you want | Query |
|---|---|
| Who called which endpoint, when | `system.serving.endpoint_usage` |
| What model handled the request | Join `endpoint_usage.served_entity_id` to `system.serving.served_entities` |
| What the request and response were | Inference table (auto_capture_config) |
| What the model or agent logged internally | `<prefix>_otel_logs` (endpoint telemetry, custom/agent endpoints) |
| Latency percentiles by version | `endpoint_usage` GROUP BY `served_entity_id` |
| Cost attribution by team or app | `endpoint_usage.usage_context` (caller-supplied tag) |

```sql
-- 7-day per-endpoint, per-team usage with model version
SELECT
  se.endpoint_name,
  eu.usage_context['team']  AS team,
  se.entity_type,
  se.foundation_model_config.model_id AS model,
  COUNT(*)                            AS calls,
  SUM(eu.input_token_count)           AS input_tokens,
  SUM(eu.output_token_count)          AS output_tokens,
  AVG(eu.execution_duration_ms)       AS avg_latency_ms
FROM system.serving.endpoint_usage eu
JOIN system.serving.served_entities se
  ON eu.served_entity_id = se.served_entity_id
WHERE eu.request_time > current_timestamp() - INTERVAL 7 DAYS
GROUP BY 1, 2, 3, 4
ORDER BY calls DESC;
```

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| An agent that surfaces personalized data | Pattern B — `ModelServingUserCredentials` for OBO; pair with UC row filters |
| A shared/public knowledge agent | Pattern A — endpoint SP with explicit UC grants |
| A production model with rollouts | Multi-entity endpoint + traffic splits + inference tables; canary at 10% |
| Compliance-grade audit | Inference tables enabled at endpoint creation; never altered after |
| Near-real-time debugging of custom or agent endpoints | Endpoint telemetry (OTel to UC); pair with inference tables for the durable audit trail |
| Production endpoints with SLA | Provisioned Throughput; `scale_to_zero_enabled: false` |
| External provider behind a unified governance surface | External Model endpoint + UC Service Credentials when supported |
| Per-team cost attribution | Callers send `usage_context: {team: "...", app: "..."}` in the request |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| `CAN_QUERY` granted to `all_users` on production endpoints | Grant by functional group; reserve broad grants for FMAPI evaluation |
| Provider keys hardcoded in app code | UC-stored secrets referenced as `{{secrets/scope/key}}` or UC Service Credentials |
| Single-entity endpoint with in-place model swaps | Multi-entity endpoint; traffic split for canary then flip |
| Inference table altered or renamed after creation | Treat as immutable; create a new endpoint with a new prefix when redesigning |
| Production endpoint with `scale_to_zero_enabled: true` | Keep at least one replica warm for predictable latency |
| Agent calling Genie or VS as the endpoint SP | OBO via `ModelServingUserCredentials` so caller-level grants apply |
| Enabling endpoint telemetry without planning table names | Table names are fixed once telemetry is configured — name them deliberately up front |

---

## Related

- [`ai-gateway-patterns.md`](ai-gateway-patterns.md) — Rate limits, guardrails, fallbacks layered on endpoints
- [`agent-governance.md`](agent-governance.md) — Agent endpoints and tool wiring
- [`../identity/authentication.md`](../identity/authentication.md) — OBO and M2M token flows
- [`../observability/audit-reference.md`](../observability/audit-reference.md) — Audit surfaces across the AI stack

---

## Public References

- [Model Serving overview](https://docs.databricks.com/aws/en/machine-learning/model-serving/)
- [Custom model serving with UC logs (telemetry)](https://learn.microsoft.com/en-us/azure/databricks/machine-learning/model-serving/custom-model-serving-uc-logs)
- [Provisioned throughput](https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/deploy-prov-throughput-foundation-model-apis)
- [External models](https://docs.databricks.com/aws/en/generative-ai/external-models/)
- [Inference tables](https://docs.databricks.com/aws/en/machine-learning/model-serving/inference-tables)
- [System tables: `serving.endpoint_usage` and `serving.served_entities`](https://docs.databricks.com/aws/en/admin/system-tables/serving)
