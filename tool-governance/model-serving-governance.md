<!--
  Synced from databricks-fieldkit on 2026-09-14
  Sources: ai/model-serving.md, ai/endpoint-telemetry.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/machine-learning/model-serving/
  This file is auto-prepared and human-reviewed before publish.
-->

# Model Serving — Endpoints, FMAPI, and Deployment

> **TL;DR**: Model Serving hosts ML models, agents, and Foundation Models behind a REST endpoint. FMAPI gives zero-config access to Databricks-hosted LLMs. For custom models: register in UC, create endpoint, query via REST or SDK. Pay-per-token (serverless) vs provisioned throughput.

---

## When to Use What

| Use Case | Approach |
|---|---|
| Call a top LLM (Llama, DBRX, Mixtral) | Foundation Model API (FMAPI) — no setup |
| Deploy your own fine-tuned model | Register in UC → Create serving endpoint |
| Deploy an MLflow agent | `log_model()` → register → endpoint |
| A/B test two model versions | Multi-entity endpoint with traffic splits |
| Guaranteed throughput / latency SLA | Provisioned Throughput endpoint |
| Embed text for vector search | FMAPI embedding models (e.g., gte-large-en) |
| Serve custom non-Python model | External Model endpoint (Azure OpenAI, Bedrock, etc.) |

---

## Foundation Model API (FMAPI)

Zero-configuration access to Databricks-managed models. No endpoint to create — just use the model name.

### Available Models

```python
# Chat models
"databricks-meta-llama-3-3-70b-instruct"
"databricks-meta-llama-3-1-70b-instruct"
"databricks-meta-llama-3-1-405b-instruct"
"databricks-dbrx-instruct"
"databricks-mixtral-8x7b-instruct"

# Embedding models (for vector search, RAG)
"databricks-gte-large-en"
"databricks-bge-large-en"

# Code models
"databricks-meta-llama-3-1-70b-instruct"   # also handles code
```

### Query via Python SDK

```python
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()

# Chat completion
response = w.serving_endpoints.query(
    name="databricks-meta-llama-3-3-70b-instruct",
    messages=[
        {"role": "system", "content": "You are a helpful sales assistant."},
        {"role": "user", "content": "Summarize this deal in 2 sentences."}
    ],
    max_tokens=256,
    temperature=0.0,        # deterministic
)
print(response.choices[0].message.content)

# With streaming
for chunk in w.serving_endpoints.stream(
    name="databricks-meta-llama-3-3-70b-instruct",
    messages=[{"role": "user", "content": "Tell me about Databricks"}],
):
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

### Query via OpenAI SDK (Compatible API)

```python
import os
from openai import OpenAI
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()
token = w.config.token

client = OpenAI(
    api_key=token,
    base_url=f"{w.config.host}/serving-endpoints",
)

response = client.chat.completions.create(
    model="databricks-meta-llama-3-3-70b-instruct",
    messages=[{"role": "user", "content": "What is Unity Catalog?"}],
    max_tokens=300,
)
print(response.choices[0].message.content)
```

### Query via REST

```bash
curl -X POST "${DATABRICKS_HOST}/serving-endpoints/databricks-meta-llama-3-3-70b-instruct/invocations" \
  -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

### Embeddings

```python
# Via SDK
response = w.serving_endpoints.query(
    name="databricks-gte-large-en",
    input=["Databricks is a data platform", "Unity Catalog governs data"],
)
embeddings = [item.embedding for item in response.data]
print(f"Dimension: {len(embeddings[0])}")   # 1024 for gte-large-en

# Via OpenAI SDK
emb = client.embeddings.create(
    model="databricks-gte-large-en",
    input="Text to embed",
)
vector = emb.data[0].embedding
```

---

## Custom Model Endpoints

### Step 1: Log and Register Model

```python
import mlflow
from databricks.sdk import WorkspaceClient

# Log a custom PyFunc model
with mlflow.start_run():
    model_info = mlflow.pyfunc.log_model(
        artifact_path="model",
        python_model=MyModel(),        # must implement predict(context, model_input)
        pip_requirements=["scikit-learn==1.5.0"],
        registered_model_name="main.models.my_classifier",
        input_example={"inputs": ["sample text"]},
    )

# Or log an MLflow flavor directly
with mlflow.start_run():
    mlflow.sklearn.log_model(
        sk_model=trained_model,
        artifact_path="model",
        registered_model_name="main.models.churn_predictor",
    )
```

### Step 2: Create Serving Endpoint

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.serving import (
    ServedEntityInput,
    EndpointCoreConfigInput,
    AutoCaptureConfigInput,
)

w = WorkspaceClient()

# Create endpoint with single entity
endpoint = w.serving_endpoints.create_and_wait(
    name="my-model-endpoint",
    config=EndpointCoreConfigInput(
        served_entities=[
            ServedEntityInput(
                entity_name="main.models.my_classifier",
                entity_version="1",
                workload_size="Small",          # Small | Medium | Large
                scale_to_zero_enabled=True,
                environment_vars={
                    "MY_CONFIG": "production",
                },
            )
        ],
        auto_capture_config=AutoCaptureConfigInput(
            catalog_name="main",
            schema_name="inference_logs",
            table_name_prefix="my_classifier",
            enabled=True,                       # log all requests/responses
        ),
    ),
)
print(endpoint.state.ready)
```

### Step 3: Query Custom Endpoint

```python
# Query custom endpoint (same API as FMAPI)
result = w.serving_endpoints.query(
    name="my-model-endpoint",
    inputs=[{"feature_1": 0.5, "feature_2": "text", "feature_3": 42}],  # for tabular models
)
print(result.predictions)

# Or for chat-format models
result = w.serving_endpoints.query(
    name="my-agent-endpoint",
    messages=[{"role": "user", "content": "analyze this deal"}],
)
```

---

## A/B Testing with Traffic Splits

```python
from databricks.sdk.service.serving import TrafficConfig, Route

w.serving_endpoints.update_config_and_wait(
    name="my-model-endpoint",
    served_entities=[
        ServedEntityInput(
            entity_name="main.models.my_classifier",
            entity_version="1",
            name="version-1",         # logical name for routing
            workload_size="Small",
        ),
        ServedEntityInput(
            entity_name="main.models.my_classifier",
            entity_version="2",
            name="version-2",
            workload_size="Small",
        ),
    ],
    traffic_config=TrafficConfig(
        routes=[
            Route(served_model_name="version-1", traffic_percentage=80),
            Route(served_model_name="version-2", traffic_percentage=20),
        ]
    ),
)
```

---

## Provisioned Throughput

For guaranteed tokens/second (no cold starts, SLA-backed):

```python
from databricks.sdk.service.serving import (
    ServedEntityInput,
    ServedModelInput,
    AiGatewayConfig,
    AiGatewayRateLimits,
    AiGatewayRateLimitKey,
    AiGatewayRateLimitRenewalPeriod,
)

w.serving_endpoints.create_and_wait(
    name="llama-provisioned",
    config=EndpointCoreConfigInput(
        served_entities=[
            ServedEntityInput(
                entity_name="system.ai.meta_llama_3_3_70b_instruct",
                min_provisioned_throughput=100,   # min tokens/sec
                max_provisioned_throughput=500,   # max tokens/sec
            )
        ]
    ),
)
```

**When to use**: High-volume production (>10 req/s), latency SLA, regulated environments.

---

## External Model Endpoints (Proxy to Other APIs)

```python
from databricks.sdk.service.serving import (
    ExternalModel,
    ExternalModelProvider,
    OpenAiConfig,
)

# Proxy Azure OpenAI through Databricks (unified auth, audit logs)
w.serving_endpoints.create_and_wait(
    name="azure-gpt4o",
    config=EndpointCoreConfigInput(
        served_entities=[
            ServedEntityInput(
                external_model=ExternalModel(
                    provider=ExternalModelProvider.OPENAI,
                    name="gpt-4o",
                    openai_config=OpenAiConfig(
                        openai_api_type="azure",
                        openai_api_base="https://your-resource.openai.azure.com",
                        openai_api_version="2024-02-01",
                        openai_deployment_name="gpt-4o-deployment",
                        openai_api_key_plaintext="your-key",   # or use secret()
                    ),
                )
            )
        ]
    ),
)
```

---

## AI Gateway (Rate Limiting, Guardrails, Routing)

> **Moved to dedicated file**: See [`ai/ai-gateway.md`](ai-gateway.md) for full coverage including Beta vs GA paths, Python SDK, REST API, Terraform, guardrails, fallbacks, system tables, external model providers, and coding agent integration.

---

## Inference Tables (Request Logging)

Automatically log all requests/responses to a Delta table:

```yaml
# In endpoint config
auto_capture_config:
  catalog_name: main
  schema_name: inference_logs
  table_name_prefix: my_endpoint
  enabled: true
```

```sql
-- Logged to: main.inference_logs.my_endpoint_payload
SELECT
  request_id,
  request_time,
  status_code,
  request.messages[0].content  AS user_message,
  response.choices[0].message.content AS assistant_response,
  response.usage.total_tokens
FROM main.inference_logs.my_endpoint_payload
ORDER BY request_time DESC
LIMIT 100;
```

---

## Permissions

```python
# Grant CAN_QUERY to a user
w.serving_endpoints.set_permissions(
    serving_endpoint_id=endpoint.id,
    access_control_list=[
        {"user_name": "user@company.com", "permission_level": "CAN_QUERY"},
        {"group_name": "data_scientists", "permission_level": "CAN_QUERY"},
        {"service_principal_name": "sp-uuid", "permission_level": "CAN_QUERY"},
    ],
)

# Via CLI
# databricks serving-endpoints set-permissions my-endpoint \
#   --json '{"access_control_list": [{"group_name": "all_users", "permission_level": "CAN_QUERY"}]}' \
#   -p <profile>
```

Permission levels:
- `CAN_QUERY` — call the endpoint
- `CAN_MANAGE` — update config, delete endpoint
- `IS_OWNER` — full control

---

## Workload Sizes Reference

| Size | vCPUs | RAM | Use When |
|---|---|---|---|
| `Small` | 4 | 16 GB | Small models, low traffic, default |
| `Medium` | 8 | 32 GB | Medium models, moderate traffic |
| `Large` | 16 | 64 GB | Large models, high concurrency |
| GPU variants | GPU + VRAM | varies | LLM fine-tunes, custom embedding models |

`scale_to_zero_enabled: true` — cold start ~60-120s; use for dev/demo; set `false` for production.

---

## Gotchas

| Issue | Cause | Fix |
|---|---|---|
| Cold start timeout in production | `scale_to_zero_enabled: true` | Set `false` for prod; keep at least 1 replica warm |
| `REQUEST_LIMIT_EXCEEDED` | Too many concurrent requests | Increase `workload_size` or use provisioned throughput |
| Model version not found | Registered model name typo or wrong catalog | Verify with `w.registered_models.get()` |
| `PERMISSION_DENIED` on query | Missing `CAN_QUERY` | Grant via `set_permissions()` |
| Inference table not populated | `auto_capture_config.enabled = false` | Update endpoint config to enable |
| External model 401 | Incorrect API key or base URL | Check `openai_api_base` trailing slash; verify key |
| FMAPI rate limit hit | Pay-per-token has soft limits | Switch to provisioned throughput or reduce concurrency |
| GPU endpoint OOM | Model too large for selected GPU | Use larger `workload_size` or quantized model variant |
| Streaming not working | Some SDK versions don't support stream | Use `w.serving_endpoints.stream()` (not `.query()`) |

---

## Performance and Data Handling Notes

Source: [docs.databricks.com/aws/en/machine-learning/model-serving/](https://docs.databricks.com/aws/en/machine-learning/model-serving/)

- **Throughput**: Model Serving can support over 25,000 queries per second with an overhead latency of less than 50ms
- **MLflow requirement**: MLflow 1.29+ required for model registration and serving
- **Foundation Model API data residency**: Inputs and outputs are stored in the workspace region, retained 30 days for abuse detection
- **Paid accounts**: Model Serving does not use user inputs or outputs to train any models or improve Databricks services
- **External model providers** (OpenAI, Anthropic): Have separate data retention policies for safety scanning; check provider terms
- **Inference logs retention**: Container build logs retained 30 days; endpoint metrics retained 14 days

---

## Related

- [`ai/agent-framework.md`](agent-framework.md) — Deploying agents to endpoints
- [`ai/vector-search.md`](vector-search.md) — Embedding models for VS
- [`cli-api/rest-api.md`](../cli-api/rest-api.md) — REST API patterns for serving
- [`mcp/managed-mcp.md`](../mcp/managed-mcp.md) — Serving endpoints as MCP servers

# Model Serving Endpoint Telemetry

> **Cloud**: Agnostic (region-limited)
> **Status**: GA (region-limited; see Prerequisites for supported Azure regions)
> **Last verified**: 2026-07-27

---

## TL;DR

Custom model serving endpoints and **agent serving endpoints** can persist **OpenTelemetry logs, traces, and metrics** to Unity Catalog Delta tables. Standard Python `logging` is captured automatically. Custom OTel spans and metrics require SDK instrumentation in the model code. Data lands in three tables (`otel_logs`, `otel_spans`, `otel_metrics`). Useful for root cause analysis, endpoint health monitoring, and compliance.

---

## When to use

| Scenario | Use Endpoint Telemetry |
|---|---|
| Debug inference failures in production | Yes -- query logs by severity |
| Monitor custom model health/latency | Yes -- custom OTel spans + metrics |
| Compliance: persist all inference activity | Yes -- UC-governed Delta tables |
| Agent serving endpoints | Yes -- same telemetry pipeline as custom model endpoints |
| Foundation Model API (pay-per-token) endpoints | No -- this is for custom model and agent serving endpoints |
| App-level telemetry (Streamlit/FastAPI) | No -- use [Apps Observability](../apps/observability.md) |

---

## Prerequisites

- UC-enabled workspace (no Arclight default storage)
- `USE CATALOG`, `USE SCHEMA`, `CREATE TABLE`, `MODIFY` on destination schema
- An existing custom model serving endpoint **or** agent serving endpoint (or a new one)
- Supported regions (Azure, as of 2026-04):
  - `canadacentral`, `westus`, `westus2`, `southcentralus`, `eastus`, `eastus2`, `centralus`, `northcentralus`
  - `swedencentral`, `westeurope`, `northeurope`, `uksouth`
  - `australiaeast`, `southeastasia`

---

## How it works

```
Custom Model Serving Endpoint
    |
    | Python logging (auto) + OTel SDK (custom)
    v
Zerobus Ingest
    |
    v
Unity Catalog Delta Tables
  ├── <prefix>_otel_logs     (auto: Python logging output)
  ├── <prefix>_otel_spans    (custom: OTel TracerProvider)
  └── <prefix>_otel_metrics  (custom: OTel MeterProvider)
```

---

## Step 1: Instrument model code

### Basic (automatic logging)

Standard Python `logging` is captured without OTel SDK:

```python
import logging

class MyModel(mlflow.pyfunc.PythonModel):
    def predict(self, context, model_input):
        logging.warning("Received inference request")
        try:
            result = model_input * 2
            return result
        except Exception as e:
            logging.error(f"Inference failed: {e}")
            raise
```

Default root level is `WARNING`. To capture DEBUG/INFO:

```python
def load_context(self, context):
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    for handler in root.handlers:
        handler.setLevel(logging.DEBUG)
```

### Custom (OTel spans + metrics)

Write model to a separate file (avoids serialization issues), then initialize OTel per-worker:

```python
# return_input_model.py
import os
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.trace import get_tracer, set_tracer_provider
from opentelemetry.metrics import get_meter, set_meter_provider
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource

# Per-worker OTel init — include worker.pid for per-worker attribution
resource = Resource.create({"worker.pid": str(os.getpid())})
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
set_tracer_provider(tracer_provider)

metric_reader = PeriodicExportingMetricReader(OTLPMetricExporter())
set_meter_provider(MeterProvider(metric_readers=[metric_reader]))

_tracer = get_tracer(__name__)
_counter = get_meter(__name__).create_counter("prediction_count", unit="1")

class MyModel(mlflow.pyfunc.PythonModel):
    def load_context(self, context):
        self.tracer = _tracer
        self.counter = _counter

    def predict(self, context, model_input):
        with self.tracer.start_as_current_span("predict") as span:
            span.set_attribute("input_shape", str(model_input.shape))
            self.counter.add(1)
            return model_input
```

Add OTel deps when logging. Use `env_pack="databricks_model_serving"` for optimized serverless deployment:

```python
import mlflow

with mlflow.start_run():
    model_info = mlflow.pyfunc.log_model(
        name="model",
        python_model="return_input_model.py",
        pip_requirements=[
            "mlflow==3.1",
            "opentelemetry-sdk",
            "opentelemetry-exporter-otlp-proto-http",
        ],
    )

# Register with optimized packing for model serving
registered = mlflow.register_model(
    model_info.model_uri,
    "catalog.schema.model_name",
    env_pack="databricks_model_serving"   # NEW: serverless-optimized deployment
)
```

---

## Step 2: Prepare Unity Catalog destination

> Azure Databricks automatically creates the necessary tables in the destination schema if they do not already exist. You only need to provide the catalog and schema; no manual `CREATE TABLE` required.

## Step 2: Enable telemetry

### New endpoint (API)

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "https://<workspace>/api/2.0/serving-endpoints" \
  -d '{
    "name": "my-endpoint",
    "config": {
      "served_entities": [{
        "name": "my-model",
        "entity_name": "my-model",
        "entity_version": "1",
        "workload_size": "Small",
        "scale_to_zero_enabled": true
      }]
    },
    "telemetry_config": {
      "table_names": {
        "logs_table": "my_catalog.observability.custom_endpoint_logs",
        "metrics_table": "my_catalog.observability.custom_endpoint_metrics",
        "traces_table": "my_catalog.observability.custom_endpoint_spans"
      }
    }
  }'
```

> **BREAKING**: `telemetry_config` is a top-level field in the endpoint create/update request, not nested inside `config`. Source: [custom-model-serving-uc-logs](https://learn.microsoft.com/en-us/azure/databricks/machine-learning/model-serving/custom-model-serving-uc-logs)

### New endpoint (UI)

Expand **Advanced options** → **AI Gateway** section → **Enable inference tables and telemetry**.

### Existing endpoint (UI)

1. Endpoint view page → **AI Gateway** section → **Edit AI Gateway** → **Enable inference tables and telemetry**
2. Select catalog/schema, optional prefix
3. Click **Update** (triggers redeployment)

---

## Step 3: Query

Key columns: `timestamp`, `severity_text`, `body`, `trace_id`, `span_id`, `attributes` (map).

```sql
-- Errors in last hour
SELECT timestamp, severity_text, body, attributes
FROM catalog.schema.endpoint_logs
WHERE severity_text = 'ERROR'
  AND timestamp > current_timestamp() - INTERVAL 1 HOUR
ORDER BY timestamp DESC;
```

---

## Limits

| Limit | Value |
|---|---|
| Max log line | 1 MB |
| Max record | 10 MB |
| Max request | 30 MB |
| Throughput before degradation | 2500 QPS |
| Delivery | At-least-once (durable once server acknowledges) |
| Table type | Managed Delta only, single-az durability |
| Schema evolution |  |
| Table names | ASCII letters, digits, underscores only |
| Recreating target tables |  |
| Telemetry latency | Logs appear in UC table a few seconds after emission |

---

## Gotchas

| Issue | Detail |
|---|---|
| **Region-limited** | Only supported in the Azure regions listed under Prerequisites; not available globally |
| **`telemetry_config` is top-level in API** | Not nested inside `config` — a common mistake when copying older examples. Place `telemetry_config` at the same level as `config` in the create/update request body. |
| **Updating telemetry triggers redeployment** | Existing endpoint traffic briefly affected |
| **`otel_spans`/`otel_metrics` need custom instrumentation** | Only `otel_logs` is automatic |
| **Root log level defaults to WARNING** | Must override in `load_context()` to capture INFO/DEBUG |
| **Write model to separate file** | Avoids serialization errors with OTel globals |
| **Arclight storage ** | Must use UC-managed Delta |
| **Cannot recreate target tables** | Plan table naming carefully |

---

## Related

- [`model-serving.md`](model-serving.md) -- Model serving overview, FMAPI, scaling
- [`production-monitoring.md`](production-monitoring.md) -- Scorer-based quality assessment on traces
- [`mlflow-tracing.md`](mlflow-tracing.md) -- MLflow Tracing (complementary to OTel)
- [`../apps/observability.md`](../apps/observability.md) -- App-level OTel telemetry
