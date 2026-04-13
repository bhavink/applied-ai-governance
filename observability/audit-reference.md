# Observability and Audit Reference

> **Purpose**: Canonical reference for the two-layer observability model in Databricks AI applications: app-level traces (MLflow) and platform-level audit (`system.access.audit`).
>
> **Audience**: Field Engineers building production observability for Databricks AI apps. Security reviewers assessing audit posture.
>
> **Last updated**: 2026-03-12

---

## 1. The Two-Layer Model

Databricks AI applications generate audit data in two separate planes. Neither alone provides the full picture.

**Application plane** (you build this): MLflow traces + custom logging. Contains human email (from `X-Forwarded-Email`), tool calls, inputs/outputs, latency, quality scores, token consumption. Stored in Delta via trace archival.

**Data plane** (platform provides this): `system.access.audit` + system tables. Contains SQL queries executed, tables accessed, executing identity (human for OBO, SP UUID for M2M), model serving requests, Genie conversations. Stored in system tables.

**Key design point**: When an app uses M2M for SQL, the data plane records the SP UUID. The human who triggered the request is only visible in the app plane. Correlating the two layers requires a shared identifier (trace ID or timestamp window).

---

## 2. App-Plane Audit (MLflow Traces)

### What MLflow Traces Capture

| Data point | Source | Example |
|---|---|---|
| Human caller | `X-Forwarded-Email` header, trace tag | `alice@company.com` |
| Tool invoked | Span name or custom tag | `get_deal_approval_status` |
| Input/output | Span inputs and outputs | Question text, response text |
| Latency | Span duration | 1200ms |
| Auth pattern | Custom tag | `OBO User`, `M2M` |

### Persisting Traces to Delta

The MLflow experiment UI trace viewer is not SQL-queryable. To enable SQL queries, call `enable_databricks_trace_archival()` programmatically. The resulting Delta table syncs every 15-20 minutes.

**Important**: The UI "Enable Monitoring" toggle does NOT create a queryable Delta table. You must call the API.

### Automated Quality Scoring

| Scorer type | Cost | Use case |
|---|---|---|
| Built-in Safety | Free | Flags unsafe, harmful, or policy-violating content |
| Built-in RelevanceToQuery | Moderate (LLM judge) | Measures whether response answers the question |
| Custom Guidelines | Higher (LLM judge) | Domain-specific rules (auth pattern correctness, PII absence) |
| Custom Code | Free | Deterministic checks (response length, regex patterns) |

Scorers run asynchronously on production traces with zero impact on application latency. Assessments are written back to the trace and appear in the Delta table.

**Gotcha**: The assessment field is `a.name`, NOT `a.assessment_name`. Early documentation referenced `assessment_name`, which does not exist.

### Multi-Turn Conversation Judges

For agents with multi-turn conversations, single-trace quality is insufficient. Session-level judges evaluate conversation quality:

| Judge | What it evaluates |
|---|---|
| `UserFrustration` | Signs of user frustration across the conversation (repeated questions, escalation language) |
| `ConversationCompleteness` | Whether the user's goal was achieved by conversation end |
| `ConversationalSafety` | Safety across the full conversation (not just individual turns) |

These judges group traces by session ID and evaluate the conversation arc, not individual responses. Register them the same way as single-turn scorers.

### Scorer Governance

| Constraint | Detail |
|---|---|
| Maximum scorers | 20 per experiment |
| Immutable pattern | Registered scorers cannot be modified — register a new version, archive the old |
| Sampling strategy | 100% for safety/security (non-negotiable), 30-50% for quality/guidelines, 5-20% for expensive custom judges |
| Backfill | `backfill_scorers()` runs scorers on historical traces with custom time ranges — use for retroactive compliance checks |

### MLflow Tracing — Implementation Patterns

#### Auto-Instrumentation (One Line)

```python
import mlflow

# Enable for your framework (call BEFORE creating any model/chain objects)
mlflow.langchain.autolog()       # LangChain + LangGraph
mlflow.openai.autolog()          # OpenAI SDK
mlflow.databricks.autolog()      # Databricks SDK (FMAPI)

# Set where traces go
mlflow.set_experiment("/Users/me@company.com/my-agent-experiment")
```

| Framework | Autolog call | What it captures |
|---|---|---|
| LangChain / LangGraph | `mlflow.langchain.autolog()` | LLM calls (prompt/response), tool invocations (args/results), chain execution time |
| OpenAI SDK | `mlflow.openai.autolog()` | Chat completions, function calls, token usage |
| Databricks SDK (FMAPI) | `mlflow.databricks.autolog()` | Serving endpoint queries, responses |

#### Manual Spans (Granular Control)

Use `@mlflow.trace` for custom tool calls or business logic not covered by auto-instrumentation:

```python
@mlflow.trace(span_type="TOOL", name="lookup_customer")
def lookup_customer(customer_id: str) -> dict:
    # Your tool logic
    result = query_database(customer_id)
    mlflow.update_current_trace(tags={"caller": caller_email, "auth_pattern": "M2M"})
    return result
```

#### Span Type Taxonomy

| Span type | Use for |
|---|---|
| `CHAIN` | Top-level agent invocation |
| `LLM` | LLM call (auto-captured by autolog) |
| `TOOL` | Tool invocation |
| `RETRIEVAL` | Vector Search or document retrieval |
| `AGENT` | Sub-agent call |
| `EMBEDDING` | Embedding generation |

#### Querying Traces

```python
# Python SDK
traces = mlflow.search_traces(
    experiment_ids=["<experiment-id>"],
    filter_string="tags.caller = 'alice@company.com'",
    max_results=100,
)
```

```sql
-- SQL (after trace archival to Delta)
SELECT request_id, tags, latency_ms, status
FROM my_catalog.traces.archived_traces
WHERE tags['caller'] = 'alice@company.com'
  AND timestamp > current_date() - INTERVAL 7 DAYS
ORDER BY timestamp DESC;
```

---

## 3. Data-Plane Audit (system.access.audit)

### What System Tables Capture

| Table | What it provides |
|---|---|
| `system.access.audit` | All API calls: SQL queries, table access, UC operations, Genie conversations |
| `system.serving.endpoint_usage` | Per-request serving metrics: tokens, status codes, latency |
| `system.ai_gateway.usage` | Token usage and routing through AI Gateway |
| `system.billing.usage` | DBU cost tracking by SKU and endpoint |

### Identity in Audit Records

| Service | Auth pattern | `user_identity.email` in audit |
|---|---|---|
| Genie Space | OBO | Human email |
| SQL Warehouse (OBO + `sql` scope via UI) | OBO | Human email |
| SQL Warehouse (M2M) | M2M | SP UUID |
| Agent Bricks (OBO) | OBO | Human email |
| Agent Bricks (automatic) | Automatic | SP UUID |

### System Table Eventual Consistency

New endpoints can take hours to days to appear. Recent data may lag by 15-60 minutes. Queries for newly deployed endpoints may return empty results initially.

---

## 4. Correlation: Bridging the Two Layers

### The Challenge

A single user interaction may generate an MLflow trace with the human's email (app plane), multiple `system.access.audit` entries with the SP UUID (data plane), and a Genie audit entry with the human's email (data plane).

### Correlation Strategy

1. Generate a `trace_id` at the agent entry point
2. Pass it through tool calls as a parameter or context variable
3. Log it in MLflow traces as a tag
4. Include it in SQL comments so it appears in the audit log query text
5. Join app-plane and data-plane on shared `trace_id` or timestamp windows

```sql
-- Illustrative: join traces with serving metrics
SELECT t.trace_id, t.state, t.execution_duration_ms,
       s.total_tokens
FROM my_catalog.my_schema.traces t
LEFT JOIN system.serving.endpoint_usage s
  ON t.trace_id = s.databricks_request_id
WHERE t.request_time >= CURRENT_DATE - INTERVAL 7 DAYS;
```

### Recommended Alerts

| Alert | Condition | Severity |
|---|---|---|
| Error rate spike | Error rate > 5% in the last hour | High |
| Latency SLA breach | P95 latency > 5000ms in the last hour | High |
| Quality score drop | Average safety score < 0.8 in the last hour | Critical |

Implement as SQL alerts in Databricks with Slack, email, or PagerDuty notification destinations.

---

## 5. Genie-Specific Observability

Genie conversations are captured in `system.access.audit` under the `aibiGenie` service name, recording conversation starts, query execution (generated SQL, table accesses), and response delivery.

| Aspect | Genie (platform audit) | App-level (MLflow traces) |
|---|---|---|
| Identity | Always human email (OBO) | Human email from X-Forwarded-Email |
| SQL queries | Generated SQL visible in audit | Not captured unless you log it |
| Quality scoring | Not available | Configurable via MLflow scorers |
| Cost tracking | Via system.billing.usage | Via system.ai_gateway.usage |


---

## 6. Design Considerations

| Consideration | Detail |
|---|---|
| **W3C Trace Context** | Not propagated with `mlflow-tracing`. Multi-service apps emit independent traces correlated via shared experiment and tags, not parent-child spans. |
| **Trace Archival Lag** | Delta table syncs every 15-20 minutes. Dashboards are not real-time. For live debugging, use the MLflow experiment UI. |
| **mlflow-tracing vs mlflow** | Production apps use `mlflow-tracing` (~5 MB). Scorer registration and trace archival setup require `mlflow[databricks]>=3.1` (~150 MB), run from a notebook. |
| **Scorer Scope** | Scorers are registered per MLflow experiment, not per serving endpoint. New experiment = re-register scorers. |
| **startup.sh conflicts** | Databricks Apps pre-installs `mlflow-skinny`, which conflicts with `mlflow-tracing`. Use a startup script to uninstall and force-reinstall. |

---

## 7. Scorer Patterns

### Recommended Production Scorers

| Scorer | Type | Sample Rate | Cost | What It Checks |
|---|---|---|---|---|
| `safety_check` | Built-in (Safety) | 100% | None | Unsafe, harmful, or policy-violating content |
| `relevance_check` | Built-in (RelevanceToQuery) | 50% | Moderate | Response answers the question |
| `guidelines_check` | Custom (Guidelines) | 30% | LLM judge | Domain rules: auth patterns, PII absence, actionable errors |
| `response_length` | Custom (Code) | 100% | None | Character count with mean/min/max aggregations |
| `has_auth_pattern` | Custom (Code) | 100% | None | Boolean: response mentions OBO, M2M, or auth_pattern |

**Sample rate rationale**: 100% for safety and code scorers (cheap or free). 50% for relevance (moderate LLM cost). 30% for guidelines (higher per-evaluation cost).

### Registration Pattern

Registration is idempotent: check if scorer exists and is running before creating. Use `get_scorer(name)` first, restart if stopped, create if missing.

### Backfilling Historical Traces

Use `backfill_scorers()` to retroactively score traces that existed before scorers were registered. Returns a job ID to monitor in the Jobs UI.

---

## 8. Four-Page Dashboard Guide

Deploy a Lakeview dashboard for end-to-end observability.

| Page | Focus | Key Widgets |
|---|---|---|
| **1. Operations** | Health check | KPI counters (requests, errors, P50/P95/P99), request volume over time, error rate trend, tool breakdown, auth pattern distribution |
| **2. Quality** | Scorer assessments | Scorer summary table, scores over time, response length by tool |
| **3. Cost** | Token and DBU spend | Daily token consumption, DBU cost, token efficiency, latency vs response size |
| **4. Errors** | Root cause analysis | Errors by tool, error timeline, recent errors table, master correlation table (traces + serving + assessments) |

---

## 9. Illustrative Correlation Queries

**Error rate by hour** (7-day window): Group traces by hour, compute error count and percentage.

```sql
SELECT DATE_TRUNC('HOUR', request_time) AS hour,
       COUNT(*) AS total,
       ROUND(COUNT(CASE WHEN state='ERROR' THEN 1 END)
             * 100.0 / COUNT(*), 2) AS error_rate
FROM my_catalog.my_schema.traces
WHERE request_time >= CURRENT_DATE - INTERVAL 7 DAYS
GROUP BY 1 ORDER BY 1;
```

**Quality scores over time** (30-day window): Explode assessments array, group by day and scorer name, compute average score and sample count.

---

## 10. System Tables Referenced

| Table | What It Provides |
|---|---|
| `system.serving.endpoint_usage` | Per-request serving metrics: tokens, status codes, latency |
| `system.serving.served_entities` | Endpoint configuration: entity names, entity IDs |
| `system.ai_gateway.usage` | Token usage, latency, routing |
| `system.billing.usage` | DBU cost tracking by SKU and endpoint |

---

## Related Documents

- [Authorization](../identity/authorization.md) - Auth patterns, token flows, identity models
