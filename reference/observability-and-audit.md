# Observability and Audit Reference

> **Purpose**: Canonical reference for the two-layer observability model in Databricks AI applications -- app-level traces (MLflow) and platform-level audit (`system.access.audit`). Documents the gap between them and how to bridge it.
>
> **Audience**: Field Engineers building production observability for Databricks AI apps. Security reviewers assessing audit posture.
>
> **Last updated**: 2026-03-12

---

## Table of Contents

1. [The Two-Layer Model](#1-the-two-layer-model)
2. [App-Plane Audit (MLflow Traces)](#2-app-plane-audit-mlflow-traces)
3. [Data-Plane Audit (system.access.audit)](#3-data-plane-audit-systemaccessaudit)
4. [Correlation: Bridging the Gap](#4-correlation-bridging-the-gap)
5. [Genie-Specific Observability](#5-genie-specific-observability)
6. [Known Gaps and Limitations](#6-known-gaps-and-limitations)

---

## 1. The Two-Layer Model

Databricks AI applications generate audit data in two separate planes. Neither plane alone provides the full picture.

```
+------------------------------------------------------------------+
|  APPLICATION PLANE (you build this)                               |
|                                                                   |
|  MLflow traces + custom logging                                   |
|  - Human email (from X-Forwarded-Email or user session)           |
|  - Tool calls, inputs, outputs                                    |
|  - Latency, error status                                          |
|  - Quality scores (automated scorers)                             |
|  - Token consumption estimates                                    |
|                                                                   |
|  Storage: MLflow experiment --> Delta table (via trace archival)   |
+------------------------------------------------------------------+
                              |
                   No platform-built join
                              |
+------------------------------------------------------------------+
|  DATA PLANE (platform provides this)                              |
|                                                                   |
|  system.access.audit + system tables                              |
|  - SQL queries executed, tables accessed                          |
|  - Executing identity (human email for OBO, SP UUID for M2M)     |
|  - Model serving requests, token usage                            |
|  - Genie conversations, UC connection access                      |
|                                                                   |
|  Storage: System tables in Unity Catalog                          |
+------------------------------------------------------------------+
```

**The core gap**: When an app uses M2M for SQL queries, the data plane records the SP UUID as the executing identity. The human who triggered the request is only visible in the app plane. There is no platform-built join between these two layers.

---

## 2. App-Plane Audit (MLflow Traces)

### What MLflow Traces Capture

MLflow traces record the application-level execution path. In a Databricks App context:

| Data point | How it is captured | Example |
|---|---|---|
| Human caller | `X-Forwarded-Email` header, logged as trace tag | `alice@company.com` |
| Service name | Custom tag set at trace start | `app-a-frontend`, `app-b-mcp-server` |
| Tool invoked | Span name or custom tag | `get_deal_approval_status` |
| Input/output | Span inputs and outputs | Question text, response text |
| Latency | Span duration | 1200ms |
| Error status | Span status code | `OK` or `ERROR` |
| Auth pattern used | Custom tag | `OBO User`, `M2M` |

### Persisting Traces to Delta

The MLflow experiment UI provides a trace viewer, but it is not queryable with SQL. To make traces queryable:

```python
from mlflow.tracing.archival import enable_databricks_trace_archival

enable_databricks_trace_archival(
    delta_table_fullname="my_catalog.my_schema.traces",
    experiment_id=EXPERIMENT_ID,
)
```

This creates a Delta table that syncs every 15-20 minutes. The table includes trace metadata, span details, and scorer assessments (if configured).

**Important**: The Databricks UI "Enable Monitoring" toggle does NOT create a queryable Delta table. You must call `enable_databricks_trace_archival()` programmatically.

### Automated Quality Scoring

MLflow supports automated scorers that run asynchronously on production traces:

| Scorer type | Cost | Use case |
|---|---|---|
| Built-in Safety | Free | Flags unsafe, harmful, or policy-violating content |
| Built-in RelevanceToQuery | Moderate (LLM judge) | Measures whether response answers the question |
| Custom Guidelines | Higher (LLM judge) | Domain-specific rules (auth pattern correctness, PII absence) |
| Custom Code | Free | Deterministic checks (response length, regex patterns) |

Scorers write assessments back to the trace. These appear in the `assessments` array in the Delta table.

### Key Schema Fields

| Column | Type | Description |
|---|---|---|
| `trace_id` | STRING | Unique trace identifier |
| `request_time` | TIMESTAMP | When the trace started |
| `state` | STRING | `OK` or `ERROR` |
| `execution_duration_ms` | DOUBLE | End-to-end latency |
| `tags` | MAP | Includes `service_name`, `tool`, custom tags |
| `assessments` | ARRAY | Scorer results; access with `a.name` and `a.feedback.value` |

**Gotcha**: The assessment field is `a.name`, NOT `a.assessment_name`. Early documentation referenced `assessment_name` -- that field does not exist.

---

## 3. Data-Plane Audit (system.access.audit)

### What System Tables Capture

Databricks system tables record platform-level operations automatically:

| Table | What it provides |
|---|---|
| `system.access.audit` | All API calls: SQL queries, table access, UC operations, Genie conversations |
| `system.serving.endpoint_usage` | Per-request serving metrics: tokens, status codes, latency |
| `system.serving.served_entities` | Endpoint configuration: entity names, entity IDs |
| `system.ai_gateway.usage` | Token usage and routing through AI Gateway |
| `system.billing.usage` | DBU cost tracking by SKU and endpoint |

### Identity in Audit Records

The critical question: whose identity appears in `system.access.audit`?

| Service | Auth pattern | `user_identity.email` in audit |
|---|---|---|
| Genie Space | OBO | Human email |
| SQL Warehouse | OBO (with `sql` scope via UI) | Human email |
| SQL Warehouse | M2M | SP UUID |
| Agent Bricks | OBO | Human email |
| Agent Bricks | Automatic passthrough | SP UUID |
| UC Connection access | Caller identity | Whoever called the proxy |

### Useful Audit Queries

**Who accessed what table in the last 7 days:**

```sql
SELECT
    user_identity.email,
    request_params.full_name_arg AS table_accessed,
    COUNT(*) as query_count,
    DATE(event_time) as query_date
FROM system.access.audit
WHERE action_name = 'commandSubmit'
  AND request_params.full_name_arg LIKE 'my_catalog%'
  AND datediff(now(), event_time) <= 7
GROUP BY user_identity.email, request_params.full_name_arg, DATE(event_time)
ORDER BY query_count DESC;
```

**Failed access attempts (permission denied):**

```sql
SELECT
    user_identity.email,
    request_params.full_name_arg AS table_name,
    response.status_code,
    event_time
FROM system.access.audit
WHERE response.status_code = 403
  AND datediff(now(), event_time) <= 7
ORDER BY event_time DESC;
```

### System Table Eventual Consistency

System tables have eventual consistency:
- New endpoints can take hours to days to appear
- Recent data may lag by 15-60 minutes
- Queries for newly deployed endpoints may return empty results initially

---

## 4. Correlation: Bridging the Gap

### The Problem

A single user interaction may generate:
- An MLflow trace with the human's email and tool calls (app plane)
- Multiple `system.access.audit` entries with the SP UUID for M2M SQL (data plane)
- A Genie audit entry with the human's email (data plane)

There is no built-in key to join these records.

### Manual Correlation Strategy

1. **Generate a `trace_id`** at the agent or app entry point
2. **Pass it through tool calls** as a parameter or context variable
3. **Log it in MLflow traces** as a trace tag
4. **Include it in SQL comments** so it appears in the audit log query text
5. **Join** app-level and platform-level audit on the shared `trace_id` or on timestamp windows

```python
# Example: Include trace_id in SQL query comment for audit correlation
trace_id = mlflow.get_current_active_span().trace_id
sql = f"""
    /* trace_id={trace_id} caller={caller_email} */
    SELECT * FROM catalog.schema.table
    WHERE user_email = '{caller_email}'
"""
```

### Cross-Layer Correlation Query

```sql
-- Join MLflow traces with serving metrics
SELECT
    t.trace_id,
    t.tags['service_name'] AS service,
    t.execution_duration_ms,
    t.state,
    s.total_tokens,
    s.input_tokens,
    s.output_tokens
FROM my_catalog.my_schema.traces t
LEFT JOIN system.serving.endpoint_usage s
    ON t.trace_id = s.databricks_request_id
WHERE t.request_time >= CURRENT_DATE - INTERVAL 7 DAYS;
```

### Alerting

Three alert types are recommended for production:

| Alert | Condition | Severity |
|---|---|---|
| Error rate spike | Error rate > 5% in the last hour | High |
| Latency SLA breach | P95 latency > 5000ms in the last hour | High |
| Quality score drop | Average safety score < 0.8 in the last hour | Critical |

These can be implemented as SQL alerts in Databricks with configurable notification destinations (Slack, email, PagerDuty).

---

## 5. Genie-Specific Observability

### Platform Audit for Genie

Genie conversations are captured in `system.access.audit` under the `aibiGenie` service name. Key events:

| Event | What it captures |
|---|---|
| Conversation start | User email, Genie space ID |
| Query execution | Generated SQL, table accesses |
| Response delivery | Result metadata |

### Genie Monitoring Suite

The `audit-logging/genie-aibi/` directory contains a complete monitoring solution:

- **Conversation activity tracking**: Daily trends, user engagement metrics
- **User activity monitoring**: Email mapping, per-user query counts
- **Query insights**: Generated SQL parsing, performance metrics
- **Real-time alerting**: Failure detection, inactive space alerts, slow query alerts
- **Delta streaming**: Near-real-time monitoring via streaming architecture

For the full Genie monitoring implementation, see [audit-logging/genie-aibi/](../audit-logging/genie-aibi/).

### Genie vs App-Level Observability

| Aspect | Genie (platform audit) | App-level (MLflow traces) |
|---|---|---|
| Identity | Always human email (OBO) | Human email from X-Forwarded-Email |
| SQL queries | Generated SQL visible in audit | Not captured unless you log it |
| Quality scoring | Not available | Configurable via MLflow scorers |
| Latency tracking | Available via system tables | Available via trace spans |
| Cost tracking | Via system.billing.usage | Via system.ai_gateway.usage |

---

## 6. Known Gaps and Limitations

### No Platform-Built Correlation

The biggest gap: there is no built-in way to join MLflow traces with `system.access.audit` entries for the same user request. You must build this correlation yourself using shared identifiers (trace IDs, timestamps, SQL comments).

### W3C Trace Context Not Propagated

When using `mlflow-tracing` (the lightweight package used in Databricks Apps), W3C trace context headers are not available. This means:

- Multi-service apps (e.g., Streamlit + MCP server) emit independent traces
- Traces are correlated via shared experiment and tags, not parent-child spans
- If full `mlflow` is used, W3C propagation can be added for true distributed tracing

### Trace Archival Lag

The Delta table created by `enable_databricks_trace_archival()` syncs every 15-20 minutes. This means:
- Dashboard data is not real-time
- Alerts evaluate on synced data, not live traces
- For real-time debugging, use the MLflow experiment UI trace viewer

### mlflow-tracing vs mlflow

Production Databricks Apps use `mlflow-tracing` (~5 MB) instead of full `mlflow` (~150 MB). Key differences:

| Available in `mlflow-tracing` | NOT available |
|---|---|
| `mlflow.start_span()` | `mlflow.set_experiment()` |
| `mlflow.update_current_trace()` | Scorer registration APIs |
| `set_destination()` | `get_tracing_context_headers_for_http_request()` |

Scorer registration and trace archival setup require `mlflow[databricks]>=3.1` (full package), run from a notebook.

### Scorer Scope

Scorers are registered against an MLflow experiment, not a serving endpoint. If you create a new experiment, you must re-register scorers.

---

## 7. Scorer Patterns

### Scorer types and cost profiles

Five scorers are recommended for production AI governance. They run asynchronously on production traces -- zero impact on application latency.

| Scorer | Type | Sample Rate | LLM Cost | What It Checks |
|---|---|---|---|---|
| `safety_check` | Built-in (Safety) | 100% | None | Flags unsafe, harmful, or policy-violating content |
| `relevance_check` | Built-in (RelevanceToQuery) | 50% | Moderate | Measures whether the response actually answers the question |
| `guidelines_check` | Custom (Guidelines) | 30% | Yes (LLM judge) | Domain rules: auth pattern identification, PII absence, opp_id inclusion, actionable errors |
| `response_length` | Custom (Code) | 100% | None | Character count with mean/min/max aggregations; catches empty or bloated responses |
| `has_auth_pattern` | Custom (Code) | 100% | None | Boolean: does the response mention OBO, M2M, or auth_pattern? |

### Sample rate rationale

- **100%** for safety and code scorers -- they are cheap or free
- **50%** for relevance -- uses an LLM judge, moderate cost per evaluation
- **30%** for guidelines -- custom LLM judge with multiple guidelines, higher per-evaluation cost

### Registration pattern (idempotent)

```python
def safe_register_and_start(scorer_obj, name, sample_rate):
    """Register and start a scorer, skipping if already active."""
    try:
        existing = get_scorer(name=name)
        if existing.sample_rate > 0:
            return existing          # Already running
        else:
            return existing.start(   # Stopped -- restart
                sampling_config=ScorerSamplingConfig(sample_rate=sample_rate)
            )
    except Exception:
        pass  # Doesn't exist yet

    registered = scorer_obj.register(name=name)
    return registered.start(
        sampling_config=ScorerSamplingConfig(sample_rate=sample_rate)
    )
```

This pattern is idempotent: re-running does not create duplicate scorers.

### Custom code scorer example

```python
@scorer(aggregations=["mean", "min", "max"])
def response_length(outputs):
    """Character count -- catches empty or bloated responses."""
    return len(outputs) if outputs else 0
```

### Custom guidelines scorer example

```python
from databricks.agents.scorers import Guidelines

guidelines_check = Guidelines(
    name="guidelines_check",
    guidelines=[
        "The response must correctly identify the auth pattern used (OBO User or M2M).",
        "The response must not contain PII such as SSN or credit card numbers.",
        "If the query involves approval status, the response must include the opp_id.",
        "Error responses must include actionable hints about permissions or access.",
    ],
)
```

### Backfilling historical traces

To retroactively score traces that existed before scorers were registered:

```python
from databricks.agents.scorers import backfill_scorers

job_id = backfill_scorers(
    scorers=["safety_check", "relevance_check", "response_length", "has_auth_pattern"],
)
print(f"Backfill job: {job_id}")  # Monitor in Databricks Jobs UI
```

---

## 8. Four-Page Dashboard Guide

Deploy a Lakeview dashboard for E2E observability across traces, quality, cost, and errors.

### Page 1: Operations Overview

The primary health check. Start here.

| Widget | What It Shows | When To Use It |
|---|---|---|
| 6 KPI counters | Total requests, errors, error rate, P50/P95/P99 latency | Glanceable health status |
| Request volume over time | Hourly request count (bar chart) | Spot traffic patterns, outages |
| Error rate trend | Hourly error percentage (line chart) | Detect degradation trends |
| Latency percentiles | P50/P95/P99 over time (multi-line) | SLA tracking, performance regression |
| Tool breakdown | Requests per tool (bar chart) | Understand usage distribution |
| Auth pattern distribution | OBO vs M2M usage | Verify correct auth pattern selection |
| Service state | Health by service_name | Identify which service is struggling |

### Page 2: Quality and Judges

Scorer assessments and response quality trends.

| Widget | What It Shows | When To Use It |
|---|---|---|
| Scorer summary table | All scorers with average score, sample count | Overall quality posture |
| Scores over time | Daily average per scorer (multi-line) | Detect quality regression |
| Average score bars | Bar chart of each scorer's average | Compare scorer performance |
| Response length by tool | Average response length per tool | Spot tools returning empty or bloated responses |

### Page 3: Cost and Tokens

Token consumption, DBU spend, and efficiency metrics.

| Widget | What It Shows | When To Use It |
|---|---|---|
| Daily token consumption | Input + output tokens over time | Track consumption trends |
| DBU cost | Daily serverless inference DBUs | Budget forecasting |
| Token efficiency | Avg tokens per request | Optimize prompt/response sizes |
| Latency vs response size | Scatter plot | Identify efficiency outliers |

### Page 4: Error Investigation

Root cause analysis and error correlation.

| Widget | What It Shows | When To Use It |
|---|---|---|
| Errors by tool | Bar chart of error count per tool | Identify failing tools |
| Error distribution | Pie chart of error types | Understand failure modes |
| Error timeline | Errors over time (line chart) | Correlate errors with deployments/changes |
| Recent errors table | Last N errors with trace details | Active incident investigation |
| Master correlation table | Joins traces + serving + assessments | Full E2E correlation for any trace |

---

## 9. Correlation Queries

### Request volume and error rate (7-day window)

```sql
SELECT
    DATE_TRUNC('HOUR', request_time) AS hour,
    COUNT(*) AS total_requests,
    COUNT(CASE WHEN state = 'ERROR' THEN 1 END) AS errors,
    ROUND(COUNT(CASE WHEN state = 'ERROR' THEN 1 END) * 100.0 / COUNT(*), 2) AS error_rate
FROM <catalog>.<schema>.traces
WHERE request_time >= CURRENT_DATE - INTERVAL 7 DAYS
GROUP BY 1
ORDER BY 1;
```

### Latency percentiles (7-day window)

```sql
SELECT
    DATE_TRUNC('HOUR', request_time) AS hour,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY execution_duration_ms) AS p50_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY execution_duration_ms) AS p95_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY execution_duration_ms) AS p99_ms
FROM <catalog>.<schema>.traces
WHERE request_time >= CURRENT_DATE - INTERVAL 7 DAYS
  AND state = 'OK'
GROUP BY 1
ORDER BY 1;
```

### Quality scores over time (30-day window)

```sql
SELECT
    DATE_TRUNC('DAY', t.request_time) AS day,
    a.name AS scorer_name,
    AVG(CAST(a.feedback.value AS DOUBLE)) AS avg_score,
    COUNT(*) AS sample_count
FROM <catalog>.<schema>.traces t
LATERAL VIEW EXPLODE(t.assessments) AS a
WHERE t.request_time >= CURRENT_DATE - INTERVAL 30 DAYS
GROUP BY 1, 2
ORDER BY 1, 2;
```

### Token consumption (30-day window)

```sql
SELECT
    DATE_TRUNC('DAY', request_time) AS day,
    SUM(input_token_count) AS total_input_tokens,
    SUM(output_token_count) AS total_output_tokens,
    SUM(input_token_count + output_token_count) AS total_tokens
FROM system.ai_gateway.usage
WHERE request_time >= CURRENT_DATE - INTERVAL 30 DAYS
GROUP BY 1
ORDER BY 1;
```

### Cost tracking (30-day window)

```sql
SELECT
    DATE_TRUNC('DAY', usage_date) AS day,
    SUM(usage_quantity) AS total_dbus,
    ROUND(SUM(usage_quantity) * 0.07, 2) AS estimated_cost_usd
FROM system.billing.usage
WHERE sku_name LIKE '%SERVERLESS_REAL_TIME_INFERENCE%'
  AND usage_date >= CURRENT_DATE - INTERVAL 30 DAYS
GROUP BY 1
ORDER BY 1;
```

### Master correlation (traces + serving + assessments)

```sql
SELECT
    t.trace_id,
    t.tags['service_name'] AS service,
    t.state,
    t.execution_duration_ms AS trace_latency_ms,
    s.total_tokens,
    s.input_tokens,
    s.output_tokens,
    COLLECT_LIST(STRUCT(a.name, CAST(a.feedback.value AS DOUBLE))) AS scores
FROM <catalog>.<schema>.traces t
LEFT JOIN system.serving.endpoint_usage s
    ON t.trace_id = s.databricks_request_id
LATERAL VIEW OUTER EXPLODE(t.assessments) AS a
WHERE t.request_time >= CURRENT_DATE - INTERVAL 7 DAYS
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY t.request_time DESC;
```

### Error correlation (extract error spans)

```sql
SELECT
    t.trace_id,
    t.tags['service_name'] AS service,
    t.tags['tool'] AS tool,
    t.execution_duration_ms,
    FILTER(
        TRANSFORM(t.spans, s -> STRUCT(s.name, s.status.status_code, s.status.description)),
        x -> x.status_code = 'ERROR'
    ) AS error_spans
FROM <catalog>.<schema>.traces t
WHERE t.state = 'ERROR'
  AND t.request_time >= CURRENT_DATE - INTERVAL 7 DAYS
ORDER BY t.request_time DESC;
```

---

## 10. Alert SQL

Three production alerts with tunable thresholds.

### Error rate spike (> 5% in last hour)

```sql
SELECT
    COUNT(CASE WHEN state = 'ERROR' THEN 1 END) * 100.0 / COUNT(*) AS error_rate
FROM <catalog>.<schema>.traces
WHERE request_time >= CURRENT_TIMESTAMP - INTERVAL 1 HOUR
HAVING error_rate > 5.0;
```

### P95 latency SLA breach (> 5000ms in last hour)

```sql
SELECT
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY execution_duration_ms) AS p95_ms
FROM <catalog>.<schema>.traces
WHERE request_time >= CURRENT_TIMESTAMP - INTERVAL 1 HOUR
    AND state = 'OK'
HAVING p95_ms > 5000;
```

### Safety score drop (average < 0.8 in last hour)

```sql
SELECT
    AVG(CAST(a.feedback.value AS DOUBLE)) AS avg_safety
FROM <catalog>.<schema>.traces t
LATERAL VIEW EXPLODE(t.assessments) AS a
WHERE a.name = 'safety_check'
    AND t.request_time >= CURRENT_TIMESTAMP - INTERVAL 1 HOUR
HAVING avg_safety < 0.8;
```

### Configuring alert notifications

After deploying alerts, configure destinations in the Databricks SQL Alerts UI:

1. Navigate to **SQL > Alerts** in the workspace sidebar
2. Open each alert
3. **Add Destination** -- supported: Slack webhook, email distribution list, PagerDuty, generic webhook

Thresholds are tunable by editing the alert SQL and redeploying.

---

## 11. System Tables Referenced

| Table | What It Provides |
|---|---|
| `system.serving.endpoint_usage` | Per-request serving metrics: tokens, status codes, latency |
| `system.serving.served_entities` | Endpoint configuration: entity names, entity IDs |
| `system.ai_gateway.usage` | Token usage, latency, routing through AI Gateway |
| `system.billing.usage` | DBU cost tracking by SKU and endpoint |

### System table eventual consistency

System tables have eventual consistency:
- New endpoints can take **hours to days** to appear
- Recent data may lag by 15-60 minutes
- Queries for newly deployed endpoints may return empty results initially

---

## 12. Additional Known Limitations

### mlflow-tracing vs mlflow (lightweight vs full)

Production apps use `mlflow-tracing` (~5 MB) instead of full `mlflow` (~150 MB):

| Available in `mlflow-tracing` | NOT available in `mlflow-tracing` |
|---|---|
| `mlflow.start_span()` | `mlflow.set_experiment()` |
| `mlflow.update_current_trace()` | `mlflow.get_experiment_by_name()` |
| `mlflow.tracing.set_destination()` | `mlflow.get_tracing_context_headers_for_http_request()` |
| `@mlflow.trace` decorator | Full MLflow tracking client, scorer registration APIs |

Scorer registration and trace archival setup require `mlflow[databricks]>=3.1` (full package), run from a notebook.

### W3C trace context propagation not available

`mlflow.get_tracing_context_headers_for_http_request()` does not exist in `mlflow-tracing`. Multi-service apps emit independent traces correlated via shared experiment and tags, not parent-child span relationships.

### Token redaction (manual span management)

For operations that handle user OAuth tokens, use `mlflow.start_span()` (not `@mlflow.trace`) for explicit control over what gets logged:

```python
span_ctx = mlflow.start_span(name="supervisor_ask")
with span_ctx as span:
    span.set_inputs({
        "question": question,
        "user_token": "[REDACTED]",       # Never log the actual JWT
        "history": f"{len(history)} messages"
    })
```

### Assessments struct field name

The assessments array uses `a.name` to access the scorer name:

```sql
-- Correct
SELECT a.name, a.feedback.value
FROM <catalog>.<schema>.traces t LATERAL VIEW EXPLODE(t.assessments) AS a

-- WRONG -- this field does not exist
SELECT a.assessment_name ...
```

### enable_databricks_trace_archival() is required

The Databricks UI experiment page has an "Enable Monitoring" toggle. Clicking it in the UI alone does NOT create a queryable Delta table. You must call `enable_databricks_trace_archival()` programmatically.

### Scorers are experiment-scoped

Scorers are registered against an MLflow experiment, not a serving endpoint. If you create a new experiment, you must re-register scorers. Scorers from one experiment do not automatically apply to another.

### startup.sh and mlflow namespace conflicts

The Databricks Apps runtime pre-installs `mlflow-skinny`, which conflicts with `mlflow-tracing`. Apps should use a startup script that uninstalls `mlflow-skinny` and force-reinstalls `mlflow-tracing` to restore shared namespace files.

---

## Related Documents

- [Identity and Auth Reference](identity-and-auth-reference.md) -- Auth patterns, token flows, identity models
- [OBO vs M2M Decision Matrix](obo-vs-m2m-decision-matrix.md) -- Auth pattern selection with audit implications
- [audit-logging/genie-aibi/](../audit-logging/genie-aibi/) -- Genie-specific monitoring and analytics suite
