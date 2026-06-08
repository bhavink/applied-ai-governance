<!--
  Synced from databricks-fieldkit on 2026-04-27
  Sources: ai/endpoint-telemetry.md
  Public docs grounding:
    - https://learn.microsoft.com/en-us/azure/databricks/machine-learning/model-serving/custom-model-serving-uc-logs
  This file is auto-prepared and human-reviewed before publish.
-->

# Endpoint Telemetry — OpenTelemetry to UC Delta

> **TL;DR**: Custom model serving endpoints can persist **OpenTelemetry logs, traces, and metrics** to Unity Catalog Delta tables. Standard Python `logging` is captured automatically; OTel spans and metrics require SDK instrumentation in the model code. Three tables are produced (`<prefix>_otel_logs`, `<prefix>_otel_spans`, `<prefix>_otel_metrics`). This is complementary to inference tables — inference tables capture request/response payloads; telemetry captures structured signals from inside the model code.

---

## When Endpoint Telemetry Earns Its Keep

| Need | Endpoint Telemetry helps |
|---|---|
| Debug inference failures with structured logs | Yes — query `<prefix>_otel_logs` by severity |
| Track custom model latency at sub-step granularity | Yes — custom OTel spans on retrieval, parsing, post-processing |
| Emit business metrics from inside the model (e.g., per-class prediction counts) | Yes — OTel `MeterProvider` |
| Compliance: persist all inference activity in UC | Yes — UC-governed Delta tables |
| Capture request/response payloads themselves | Use **inference tables** instead (see [`../tool-governance/model-serving-governance.md`](../tool-governance/model-serving-governance.md)) |
| Foundation Model API endpoints | Not applicable — telemetry attaches to custom model endpoints |

---

## Architecture

```
Custom Model Serving Endpoint
        │
        │ Python logging (auto)
        │ OTel SDK (custom: TracerProvider, MeterProvider)
        ▼
Zerobus Ingest
        │
        ▼
Unity Catalog Delta Tables
  ├── <prefix>_otel_logs      (auto: Python logging output)
  ├── <prefix>_otel_spans     (custom: tracer spans)
  └── <prefix>_otel_metrics   (custom: counters, histograms, gauges)
```

The telemetry path is independent of MLflow Tracing. Use **MLflow Tracing** for application-plane span structure across the agent stack; use **endpoint telemetry** for OTel-standard signals from inside the model code that downstream OTel-aware tooling can consume.

---

## Configure Telemetry on the Endpoint

```json
{
  "name": "claims-classifier",
  "config": {
    "served_entities": [{
      "name": "claims-v2",
      "entity_name": "main.models.claims",
      "entity_version": "2",
      "workload_size": "Small",
      "scale_to_zero_enabled": true
    }],
    "telemetry_config": {
      "table_names": {
        "logs_table":    "main.observability.claims_logs",
        "metrics_table": "main.observability.claims_metrics",
        "traces_table":  "main.observability.claims_spans"
      }
    }
  }
}
```

UI path: Endpoint view → **Endpoint telemetry** → **Add** → select catalog/schema/prefix → **Update** (triggers a redeployment).

> **Updates trigger redeployment.** Schedule telemetry config changes in a maintenance window.

---

## Instrumenting Model Code

### Logs (automatic)

Standard Python `logging` is captured without OTel SDK:

```python
import logging

class MyModel(mlflow.pyfunc.PythonModel):
    def predict(self, context, model_input):
        logging.warning("Received inference request")
        try:
            return self._infer(model_input)
        except Exception as e:
            logging.error(f"Inference failed: {e}")
            raise
```

Default root level is `WARNING`. To capture `INFO` or `DEBUG`, override in `load_context`:

```python
def load_context(self, context):
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    for handler in root.handlers:
        handler.setLevel(logging.DEBUG)
```

### Spans and metrics (custom)

Initialize OTel providers per-worker, ideally in a separate Python file referenced by the MLflow model to keep serialization clean:

```python
# return_input_model.py
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.trace import get_tracer, set_tracer_provider
from opentelemetry.metrics import get_meter, set_meter_provider
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter

tracer_provider = TracerProvider()
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
set_tracer_provider(tracer_provider)

set_meter_provider(MeterProvider(metric_readers=[
    PeriodicExportingMetricReader(OTLPMetricExporter())
]))

_tracer  = get_tracer(__name__)
_counter = get_meter(__name__).create_counter("prediction_count", unit="1")

class MyModel(mlflow.pyfunc.PythonModel):
    def load_context(self, context):
        self.tracer  = _tracer
        self.counter = _counter

    def predict(self, context, model_input):
        with self.tracer.start_as_current_span("predict") as span:
            span.set_attribute("input_shape", str(model_input.shape))
            self.counter.add(1)
            return self._infer(model_input)
```

Add OTel deps when logging the model:

```python
mlflow.pyfunc.log_model(
    name="model",
    python_model="return_input_model.py",
    pip_requirements=[
        "mlflow==3.1",
        "opentelemetry-sdk",
        "opentelemetry-exporter-otlp-proto-http",
    ],
)
```

---

## Querying Telemetry

Logs share a common OTel-aligned schema: `timestamp`, `severity_text`, `body`, `trace_id`, `span_id`, `attributes` (map).

```sql
-- Errors in the last hour
SELECT timestamp, severity_text, body, attributes
FROM main.observability.claims_logs
WHERE severity_text = 'ERROR'
  AND timestamp > current_timestamp() - INTERVAL 1 HOUR
ORDER BY timestamp DESC;

-- Span latency by custom span name
SELECT
  attributes['span.name']      AS span_name,
  approx_percentile(duration_ms, 0.50) AS p50_ms,
  approx_percentile(duration_ms, 0.95) AS p95_ms,
  approx_percentile(duration_ms, 0.99) AS p99_ms,
  COUNT(*)                     AS samples
FROM main.observability.claims_spans
WHERE timestamp > current_timestamp() - INTERVAL 1 DAY
GROUP BY 1
ORDER BY p95_ms DESC;
```

Joining `trace_id` across tables lets you correlate a structured log line back to the span it came from and any custom metric emitted in the same span.

---

## Limits to Plan Around

| Limit | Value |
|---|---|
| Max log line | 1 MB |
| Max record | 10 MB |
| Max request | 30 MB |
| Throughput before degradation | ~2,500 QPS |
| Delivery semantics | At-least-once |
| Table type | Managed Delta only, same region |
| Schema | Treat as immutable — design table names and prefixes up front |

> **Plan table naming carefully** — the telemetry tables are configured by full UC name and cannot be recreated under the same prefix later without changing endpoint config.

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| A production agent or model endpoint | Telemetry enabled at endpoint creation; logs to a per-team UC schema |
| Sub-step latency tracking inside the model | Custom OTel spans wrapped around retrieval, parsing, post-processing |
| Per-class business metrics | OTel counters with attributes for the class label |
| High-volume endpoints near 2,500 QPS | Sampling at the model-code level (e.g., emit detailed spans only for 1-in-N requests) |
| Cross-correlation with MLflow Tracing | Propagate `trace_id` as a span attribute; both planes can be joined on it |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| OTel provider initialization inline in `predict()` | Per-worker init in a separate file (avoids serialization issues with OTel globals) |
| Default root logger left at `WARNING` when `INFO` signals are needed | Override in `load_context` so the desired severity is exported |
| Telemetry config change during peak traffic | Schedule for a maintenance window — config update redeploys the endpoint |
| Renaming or recreating telemetry tables under the same prefix | Plan UC names up front; pick a new prefix when redesigning |
| Treating telemetry tables as request/response audit | Use **inference tables** for payload audit; telemetry is for structured signals |

---

## Related

- [`audit-reference.md`](audit-reference.md) — End-to-end audit story across system tables and telemetry
- [`agent-tracing.md`](agent-tracing.md) — MLflow Tracing for the agent application plane
- [`../tool-governance/model-serving-governance.md`](../tool-governance/model-serving-governance.md) — Endpoint permissions, identity propagation, inference tables

---

## Public References

- [Custom model serving with UC logs](https://learn.microsoft.com/en-us/azure/databricks/machine-learning/model-serving/custom-model-serving-uc-logs)
- [OpenTelemetry SDK (Python)](https://opentelemetry.io/docs/languages/python/)
- [OTLP HTTP exporters](https://opentelemetry.io/docs/specs/otlp/)
