<!--
  Synced from databricks-fieldkit on 2026-07-14
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

## UC OTel Tracing — Traces Directly in Unity Catalog (Public Preview)

MLflow (>= 3.11.0) supports writing traces directly into Unity Catalog Delta tables in OpenTelemetry format, as an alternative to the default MLflow control-plane storage. This is primary storage rather than a periodic copy, so there's no archival lag between when a span completes and when it's queryable.

```python
from mlflow.entities.trace_location import UnityCatalog

experiment = mlflow.set_experiment(
    experiment_name="/Users/me@company.com/my-agent-traces",
    trace_location=UnityCatalog(
        catalog_name="main",
        schema_name="mlflow_traces",
        table_prefix="my_otel",
    ),
)
```

Each experiment gets four governed tables: `<prefix>_otel_spans`, `_otel_annotations`, `_otel_logs`, `_otel_metrics`. Grant `USE_CATALOG`, `USE_SCHEMA`, `MODIFY`, and `SELECT` explicitly — `ALL_PRIVILEGES` does not cover these tables. What this unlocks for tracing patterns:

- **Span-level SQL queries** against governed Delta tables, not just trace-level lookups via `mlflow.search_traces()`
- **Unlimited retention** under standard Delta lifecycle management, instead of platform-managed limits
- **Third-party OTLP client support** — Langfuse, Jaeger, or any OTLP-compatible exporter can write into the same governed tables via the Databricks OTLP endpoint
- Production Monitoring on UC-stored traces requires an explicit SQL warehouse ID: `set_databricks_monitoring_sql_warehouse_id()` or the `MLFLOW_TRACING_SQL_WAREHOUSE_ID` env var

The UC trace location binding is set at experiment creation and cannot be changed afterward — plan catalog/schema/table-prefix naming before creating the experiment. Multiple experiments can share the same UC trace location. See [Store MLflow traces in Unity Catalog](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/tracing/trace-unity-catalog).

---

## Production Monitoring — Scorers on Live Traces

Production Monitoring runs scorers on sampled production traces and attaches the assessments back to the traces as feedback. The same scorers used in development (`mlflow.genai.evaluate()`) work in production.

### Scorer types

| Type | Purpose |
|---|---|
| **Built-in LLM judges** (`Safety`, `Guidelines`) | Off-the-shelf safety and policy checks |
| **Custom judges** (`make_judge`) | Domain-specific assessment with multi-level outcomes |
| **Custom code scorers** (`@scorer` decorator) | Programmatic checks (regex, length, schema validity) |
| **Multi-turn conversation judges** (`ConversationCompleteness`, `UserFrustration`, `ConversationalSafety`, `KnowledgeRetention`, `ConversationalGuidelines`, `ConversationalRoleAdherence`, `ConversationalToolCallEfficiency`) | Whole-conversation assessment, grouped by session tag |

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

Multi-turn judges aggregate traces by the `mlflow.trace.session` tag, considering a conversation complete after a configurable inactivity window (default 5 minutes, tunable via `MLFLOW_ONLINE_SCORING_DEFAULT_SESSION_COMPLETION_BUFFER_SECONDS`). Use these for chat agents to detect frustration, abandonment, incomplete resolution, or role drift across a full conversation — patterns single-trace scorers miss.

### Judge alignment

Custom LLM judges can be trained to match an organization's own evaluation standards: provide ratings against a judge's past assessments from the **Judges** tab in the MLflow Experiment UI, and the judge incorporates that feedback going forward. Built-in judges can also be created directly from the UI without writing code — select scope (traces or sessions), judge type, and sampling configuration.

Judge models can be overridden per scorer when a workspace needs a specific model for evaluation, for example `Correctness(model="databricks:/databricks-gpt-5-mini")`.

### Querying traces with natural language

Two assistants can query MLflow traces conversationally instead of writing `search_traces()` calls by hand: **Genie Code** (the Databricks DS Agent, available from the MLflow Experiment UI or notebook panel) for ad hoc trace and evaluation analysis, and the **MLflow MCP server** for AI coding assistants (VS Code, Cursor, Claude Desktop) that need programmatic trace access during development.

The MLflow MCP server (`mlflow[databricks,mcp]>=3.5.1`) exposes trace search, retrieval, annotation, and tag management as MCP tools, authenticated with a workspace PAT (`DATABRICKS_TOKEN`) or, for CI/CD, a service principal's client ID/secret. It's an interactive dev-time tool — not a substitute for the production monitoring lifecycle below.

```json
// .vscode/mcp.json (same pattern for Cursor's .cursor/mcp.json)
{
  "servers": {
    "mlflow-mcp": {
      "command": "uv",
      "args": ["run", "--with", "mlflow[databricks,mcp]>=3.5.1", "mlflow", "mcp", "run"],
      "env": {
        "MLFLOW_TRACKING_URI": "databricks",
        "DATABRICKS_HOST": "https://your-workspace.cloud.databricks.com",
        "DATABRICKS_TOKEN": "<your-pat>"
      }
    }
  }
}
```

Once running, an assistant can answer questions like "show me the last 10 traces with errors" or "add feedback to trace tr-abc123" directly against the workspace's MLflow trace store.

### Third-Party Evaluation Scorers

Alongside the built-in judges above, MLflow (>= 3.1.0) wraps five third-party evaluation frameworks as scorers that plug into the same `mlflow.genai.evaluate()` call: **DeepEval** (broadest coverage — RAG, agentic, conversational, safety metrics), **RAGAS** (deep RAG context metrics), **Arize Phoenix** (lightweight hallucination/relevance/toxicity), **TruLens** (agent trace analysis — goal/plan/action alignment), and **Guardrails AI** (rule-based, zero-LLM-cost checks: PII, jailbreak detection, secrets scanning).

```python
from mlflow.genai.scorers.deepeval import AnswerRelevancy
from mlflow.genai.scorers.ragas import Faithfulness
from mlflow.genai.scorers.guardrails import DetectPII

results = mlflow.genai.evaluate(
    data=eval_dataset,
    scorers=[
        AnswerRelevancy(threshold=0.7, model="databricks:/databricks-gpt-5-mini"),
        Faithfulness(model="databricks:/databricks-gpt-5-mini"),
        DetectPII(pii_entities=["CREDIT_CARD", "SSN", "EMAIL_ADDRESS"]),
    ],
)
```

Start with built-in judges for common needs; reach for a third-party scorer when you need a specialized metric a built-in judge doesn't cover (agent plan quality, BLEU/ROUGE, deterministic jailbreak/PII detection without an LLM call). Before adopting any third-party evaluation package, audit its transitive dependencies as you would any new package — some evaluation-framework integrations pull in additional third-party SDKs with their own dependency chains and known supply-chain advisories; pin exact versions and run a dependency audit before deploying.

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
| Chat agent quality | Multi-turn judges (`UserFrustration`, `ConversationCompleteness`, `KnowledgeRetention`, and related) keyed on session ID |
| Governed, span-level trace storage with unlimited retention | UC OTel Tracing with a UC trace location set at experiment creation |
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
