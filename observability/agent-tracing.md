<!--
  Synced from databricks-fieldkit on 2026-04-27
  Sources: ai/mlflow-tracing.md, ai/production-monitoring.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/mlflow3/genai/tracing/
    - https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/eval-monitor/production-monitoring
    - https://mlflow.org/docs/latest/llms/tracing/
  This file is auto-prepared and human-reviewed before publish.
-->

# Agent Tracing and Production Monitoring

> **TL;DR**: MLflow Tracing captures structured spans for every LLM call, tool call, retrieval, and chain step inside an agent. Spans land in MLflow experiments, can be archived to UC Delta, and feed continuous quality assessment via MLflow Production Monitoring scorers (LLM judges, custom code scorers, multi-turn conversation judges). Tracing is the **application plane** of agent observability; UC system tables are the **data plane**. A complete governance posture instruments both and correlates them via shared identifiers (trace ID, session ID, user email).

---

## Two Planes of Agent Observability

| Plane | Source | Captures |
|---|---|---|
| **Application plane** (MLflow Tracing) | Your instrumentation | Tool calls, retrieval steps, prompts and responses, latency per span, token usage, scorer assessments, custom tags (caller, session, app version) |
| **Data plane** (UC system tables) | Platform automatic | SQL queries (`system.access.audit`), serving endpoint usage (`system.serving.endpoint_usage`), Genie conversations, AI Gateway requests (`system.ai_gateway.usage`) |

Each plane sees a different cut of the same request. Correlate the two via:
- **Trace ID** when the agent propagates it as a query tag or HTTP header
- **Session ID** for multi-turn conversations
- **User email + timestamp window** when no shared ID exists

> **Design principle**: under M2M auth, the data plane records the service principal as the executing identity. The human caller is only visible in the application plane. If audit needs to attribute every action to a human, the application plane must capture and persist the caller identity.

---

## Tracing Patterns

### Auto-instrumentation per framework

```python
import mlflow

mlflow.langchain.autolog()    # LangChain + LangGraph
mlflow.openai.autolog()       # OpenAI SDK
mlflow.databricks.autolog()   # Databricks SDK (FMAPI)
```

Auto-logging captures LLM calls (prompt and response), tool invocations (args and results), and chain execution time without explicit instrumentation. Call **before** creating the LLM or chain object.

### Manual spans for granular control

```python
import mlflow

@mlflow.trace(name="retrieve_docs", span_type="RETRIEVAL")
def retrieve_docs(query: str, user_email: str) -> list[dict]:
    span = mlflow.get_current_active_span()
    if span:
        span.set_attribute("user.email", user_email)
        span.set_attribute("filter", "owner_email")
    return vs_client.query(...)

@mlflow.trace(name="generate_answer", span_type="LLM")
def generate_answer(context: str, question: str) -> str:
    return endpoint.query(...)
```

### Span types reference

| Span type | Use for |
|---|---|
| `LLM` / `CHAT_MODEL` | Language model calls |
| `RETRIEVAL` | Vector search, document retrieval |
| `TOOL` | Tool execution (UC functions, custom callables) |
| `CHAIN` | Multi-step pipeline |
| `AGENT` | Top-level agent loop |
| `EMBEDDING` | Embedding generation |
| `RERANKER` | Reranking retrieved docs |
| `PARSER` | Output parsing, structured extraction |

### Tag traces for filtering

Use `update_current_trace()` to attach queryable tags inside a span:

```python
mlflow.update_current_trace(tags={
    "service_name": "claims-mcp-server",
    "tool":         "get_claim_history",
    "caller":       caller_email,
    "auth_pattern": "OBO_USER",
})
```

Tag conventions worth standardizing across an organization:
- `caller` — human email (from OBO) or SP UUID (from M2M)
- `session.id` — opaque session identifier
- `app.version` — app or agent version
- `auth_pattern` — `OBO_USER`, `M2M`, or a custom enum

---

## Production Monitoring — Scorers on Live Traces

Production Monitoring runs scorers on sampled production traces and attaches the assessments back to the traces as feedback. The same scorers used in development (`mlflow.genai.evaluate()`) work in production.

### Scorer types

| Type | Purpose |
|---|---|
| **Built-in LLM judges** (`Safety`, `Guidelines`) | Off-the-shelf safety and policy checks |
| **Custom judges** (`make_judge`) | Domain-specific assessment with multi-level outcomes |
| **Custom code scorers** (`@scorer` decorator) | Programmatic checks (regex, length, schema validity) |
| **Multi-turn conversation judges** (`ConversationCompleteness`, `UserFrustration`, `ConversationalSafety`) | Whole-conversation assessment, grouped by session tag |

### Lifecycle

```python
from mlflow.genai.scorers import Safety, ScorerSamplingConfig

safety = Safety().register(name="safety_check")
safety = safety.start(sampling_config=ScorerSamplingConfig(sample_rate=1.0))
# ... later ...
safety = safety.update(sampling_config=ScorerSamplingConfig(sample_rate=0.5))
safety = safety.stop()
```

Scorers are immutable — `.start()`, `.update()`, `.stop()` each return a new instance.

### Sampling strategy

| Priority | Rate | Use for |
|---|---|---|
| Critical (safety, security, compliance) | 1.0 | Every trace |
| Moderate (guidelines, relevance) | 0.3 – 0.5 | Steady-state quality monitoring |
| Expensive (complex LLM judges) | 0.05 – 0.2 | Cost-conscious production |

### Multi-turn judges

Multi-turn judges aggregate traces by the `mlflow.trace.session` tag, considering a conversation complete after a configurable inactivity window. Use these for chat agents to detect frustration, abandonment, or incomplete resolution patterns that single-trace scorers miss.

---

## Archiving Traces to UC

For long-term retention, dashboarding, and custom analysis, archive traces and assessments to UC Delta:

```python
from mlflow.tracing.archival import enable_databricks_trace_archival

enable_databricks_trace_archival(
    delta_table_fullname="main.observability.archived_traces",
    experiment_id="<EXPERIMENT_ID>",
)
```

Archived tables can be joined to `system.serving.endpoint_usage`, `system.access.audit`, and `system.ai_gateway.usage` on shared keys (request ID, timestamp window, identity) — this is how the application plane and data plane reunite for complete audit.

---

## Tracing in Production Apps

Databricks Apps (Streamlit, FastAPI, custom MCP servers) run a slimmer environment than notebooks. Two practical considerations:

1. Use the lightweight **`mlflow-tracing`** package, not full `mlflow`, in app environments. It has the trace decorators and tag APIs but omits experiment management and notebook-only features.
2. Configure the trace destination explicitly:

```python
from mlflow.tracing import set_destination
from mlflow.tracing.destination import Databricks

set_destination(Databricks(experiment_name="/Users/me/my-agent"))
```

Enable async trace logging in production so tracing never blocks request handling:

```python
import os
os.environ.setdefault("MLFLOW_ENABLE_ASYNC_TRACE_LOGGING", "true")
os.environ.setdefault("MLFLOW_ASYNC_TRACE_LOGGING_MAX_WORKERS", "10")
```

Wrap initialization defensively so a tracing failure does not crash the app — provide a no-op stub for `@mlflow.trace` decorators when the SDK fails to load.

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| Any production agent | MLflow Tracing with auto-instrumentation + manual spans for tools |
| An app that needs caller attribution under M2M | Tag every trace with `caller` (human email from OBO) and `session.id` |
| Continuous safety checks on live traffic | `Safety` scorer at `sample_rate=1.0` |
| Quality regression detection | `Guidelines` or custom judges at moderate sampling, dashboarded on the experiment |
| Chat agent quality | Multi-turn judges (`UserFrustration`, `ConversationCompleteness`) keyed on session ID |
| Long-term audit retention | UC Delta archival of traces and assessments |
| Cross-plane audit reconciliation | Same trace ID or request ID propagated to data-plane tables when possible |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Calling `autolog()` after creating LLM/chain objects | Call before any object creation |
| Tracing without setting an experiment | Always set destination explicitly in apps; use `set_experiment` in notebooks |
| Capturing prompts and responses without size limits | `mlflow.set_tracing_config(max_string_length=...)` to bound trace size |
| Class-based scorers in production monitoring | Use `@scorer` decorator functions; production monitoring requires this form |
| Type hints requiring imports in scorer signatures | Avoid `List`, `Dict` annotations — they break scorer serialization |
| Synchronous trace logging in high-QPS apps | Enable `MLFLOW_ENABLE_ASYNC_TRACE_LOGGING` |

---

## Audit Surfaces — Cross-Plane Joins

```sql
-- Combine app-plane traces with data-plane endpoint usage
SELECT
  t.trace_id,
  t.tags['caller']         AS human_caller,
  t.execution_time_ms      AS app_latency_ms,
  eu.requester             AS exec_identity,
  eu.input_token_count,
  eu.output_token_count,
  eu.usage_context
FROM main.observability.archived_traces t
JOIN system.serving.endpoint_usage eu
  ON t.databricks_request_id = eu.databricks_request_id
WHERE t.timestamp_ms > UNIX_MILLIS(current_timestamp() - INTERVAL 1 DAY);
```

When the app propagates a request ID through to the endpoint call, this join recovers the full picture: who the human caller was (from app-plane tags) and what the platform-recorded executing identity was (data-plane).

---

## Related

- [`audit-reference.md`](audit-reference.md) — System tables and the data-plane audit story
- [`endpoint-telemetry.md`](endpoint-telemetry.md) — OTel logs/spans/metrics from inside model code
- [`../tool-governance/agent-governance.md`](../tool-governance/agent-governance.md) — Agent design that produces well-tagged traces

---

## Public References

- [MLflow Tracing on Databricks](https://docs.databricks.com/aws/en/mlflow3/genai/tracing/)
- [MLflow Tracing (open-source docs)](https://mlflow.org/docs/latest/llms/tracing/)
- [Production monitoring with scorers](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/eval-monitor/production-monitoring)
- [Trace archival to UC Delta](https://docs.databricks.com/aws/en/mlflow3/genai/tracing/prod-tracing/)
