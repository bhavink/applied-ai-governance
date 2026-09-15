<!--
  Synced from databricks-fieldkit on 2026-09-14
  Sources: ai/ai-gateway.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/ai-gateway/
    - https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/overview-beta
  This file is auto-prepared and human-reviewed before publish.
-->

# AI Gateway — Governance, Routing, and Observability for LLMs, MCPs, and Coding Agents

> **TL;DR**: Unity AI Gateway is the Databricks central AI governance layer with **three architectural layers**: (1) **AI assets** — Unity Catalog manages models, functions, connections, and AI services (including MCP Services and Agent Services) as UC securables; (2) **AI traffic** — UAG is the central control plane for LLMs, MCP Services, and Agent Services with rate limits, fallbacks, hard spend caps, usage tracking, and inference logging; (3) **AI service behavior** — Service Policies (ABAC) govern content and tool calls based on caller identity and content, with guardrails as a built-in subset. For **LLMs**: sidebar experience with `system.ai_gateway.usage`, native multi-provider APIs (OpenAI Responses / Anthropic Messages / Gemini), 6-template LLM-based guardrails, OTel agent telemetry, and Databricks Apps agent routing. For **MCPs**: MCP Services are now UC securables with tool filtering, service policies, and rate limits. For **Agents**: Agent Services are registered as UC securables and governed alongside tables and models. For the **previous path**: model serving endpoints with safety/PII/keyword guardrails and `system.serving.endpoint_usage`. Treat all as one governance surface; pick the path by which capability you need.
>
> **GA**: Unity AI Gateway went **generally available 2026-08-04**. Guardrails/service policies, budgets and hard spend caps, rate limits, usage tracking, inference tables, traffic splitting and fallbacks, native provider APIs, coding-agent integration, MCP Services, and Agent Services are all GA. **Still Beta**: Smart Routing (quality/cost/availability-aware dynamic routing) and the Supervisor API (workspace admins enable from the **Previews** page). The Beta-period "no charge for the gateway feature itself" language no longer applies — check current pricing.
> **Region**:  on AWS GovCloud or Azure Government.
> **Doc paths**: the `-beta` suffixed URLs are retired. `overview-beta` → `/ai-gateway/`; `configure-endpoints-beta` → `model-services`; `query-endpoints-beta` → `query-model-services`; `coding-agent-integration-beta` → `coding-agent-integration-model-services`; `usage-tracking-beta`, `cost-observability-beta`, `inference-tables-beta`, `rate-limits-beta`, `configure-traffic-splitting-beta` all drop the suffix.

---

## Three Pillars of Unity AI Gateway

| Pillar | What it governs | Key surfaces |
|---|---|---|
| **LLMs** (sidebar) | Agents, LLM endpoints, coding agents (Cursor, Codex CLI, Gemini CLI, Claude Code) | New gateway endpoints, sidebar UI, `system.ai_gateway.usage`, native multi-provider APIs, OTel agent telemetry, hard spend caps |
| **MCP Services** | MCP servers registered as UC securables (Google Drive, Jira, Slack, GitHub, custom) | Tool filtering, service policies, rate limits, audit logging under UAG |
| **Agent Services** | AI agents registered as UC securables | Governed alongside tables, models, and functions in UC |
| **Model serving endpoints** (previous) | External model endpoints, FMAPI, custom model endpoints | `PUT /api/2.0/serving-endpoints/{name}/ai-gateway`, `system.serving.endpoint_usage`, safety/PII/keyword guardrails |

> **Key decision**: Use the sidebar gateway (LLM pillar) for coding agent governance, custom API governance, multi-provider native APIs, and OTel agent telemetry. Register MCP servers as MCP Services (UC securables) to get tool filtering and service policies. Register agents as Agent Services for UC-native governance. Use the serving endpoints path for safety/PII/keyword guardrails on existing model serving endpoints, custom models, and production workloads not yet on the sidebar.

---

## LLM Pillar — Sidebar vs Serving Endpoints (Detail Matrix)

| Aspect | Unity AI Gateway (sidebar) | AI Gateway on Serving Endpoints |
|---|---|---|
| **Setup** | GA — create model services; no Previews toggle needed (Smart Routing and Supervisor API still require it) | Configure on any existing serving endpoint |
| **API surface** | New standalone endpoints, sidebar UI | `PUT /api/2.0/serving-endpoints/{name}/ai-gateway` |
| **Guardrails** | LLM-based: PII redact/block, unsafe content, jailbreak, hallucination, custom (Preview) | Safety, PII, keyword filters (Public Preview, GA path) |
| **Coding agents** | Cursor, Codex CLI, Gemini CLI, Claude Code | N/A |
| **Databricks Apps agents** | Route LLM calls from Apps-deployed agents through UAG (see [Apps agent routing](#govern-llm-usage-from-databricks-apps-agents)) | N/A |
| **Custom APIs** | Yes — govern arbitrary external APIs (same access controls, rate limits, logging) | No |
| **OpenTelemetry agent telemetry** | Native — push agent metrics/logs to UC Delta | No |
| **System table** | `system.ai_gateway.usage` | `system.serving.endpoint_usage` + `system.serving.served_entities` |
| **Cost dashboard** | Built-in UAG usage dashboard (Overview, Performance, Usage, Coding Agents tabs) | Standard system table queries |
| **Inference table payload limit** | 10 MiB | 1 MiB |
| **Inference table delivery** | Minutes | Up to 1 hour |
| **Native API support** | OpenAI Responses, Anthropic Messages, Gemini | OpenAI-compatible only |
| **Traffic splitting** | Yes — distribute requests across multiple model backends | Yes (entity-level) |

### Capabilities at a glance (sidebar gateway)

- **Permissions** — control endpoint access by user/group/SP
- **Usage tracking** — endpoint, user, team, request-tag granularity (`system.ai_gateway.usage`)
- **Inference tables** — request/response payload logging to UC Delta
- **Operational metrics** — real-time endpoint health and provider availability
- **Rate limits** — endpoint, user, group level (calls + tokens)
- **Hard spend caps** — stop requests when a budget is reached (blocks traffic, not just alerts); approximate, see Gotcha #24
- **Cost observability** — billable usage system table + pre-built usage dashboard
- **Fallbacks** — multi-provider failover on errors
- **Traffic splitting** — distribute across model backends
- **Custom APIs** — govern non-LLM external APIs with same primitives
- **Provider switching** — change models without code changes
- **Apps agent routing** — Databricks Apps agents route LLM calls through UAG
- **Service policies (ABAC)** — attribute-based access control governing content and tool calls (see [Service Policies](#service-policies-abac))

### Related Microsoft Learn topics (LLM pillar)

| Topic | What it covers |
|---|---|
| [Unity AI Gateway for agents and LLMs](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/) | Overview and getting started |
| [Configure Unity AI Gateway endpoints](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/model-services) | Create and configure gateway endpoints |
| [Query Unity AI Gateway endpoints](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/query-model-services) | OpenAI client + supported APIs |
| [Monitor usage via system tables](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/usage-tracking) | `system.ai_gateway.usage` |
| [Monitor cost](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/cost-observability) | Billable usage table + usage dashboard |
| [Inference tables](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/inference-tables) | Request/response payload audit |
| [Configure rate limits](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/rate-limits) | Capacity and cost controls |
| [Configure traffic splitting](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/configure-traffic-splitting) | Distribute requests across model backends |
| [Integrate with coding agents](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/coding-agent-integration-model-services) | Cursor, Gemini CLI, Codex CLI, Claude Code |
| [Govern LLM usage from your agent](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/agent-framework/author-agent#ai-gateway) | Apps-deployed agents → UAG routing |
| [Tutorial: Govern a coding agent's GitHub MCP access](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/govern-coding-agent-tutorial) | Restrict a coding agent's GitHub MCP tool access via UC permissions + a built-in service policy |
| [Manage budgets](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/budgets) | Per-user thresholds and spend caps across Databricks-hosted and external providers |
| [Foundation model permissions](https://learn.microsoft.com/en-us/azure/databricks/machine-learning/foundation-model-apis/model-uc-permissions) | Restrict which Databricks-hosted foundation models an org can access, account-wide or per group — the "who can use which LLM at all" control, distinct from rate limits |

### Related AWS docs (asset/traffic/behavior governance overview)

| Topic | What it covers |
|---|---|
| [AI governance overview](https://docs.databricks.com/aws/en/ai-gateway/ai-governance) | Frames UAG + UC as three governance dimensions — asset (UC privileges on models/MCP Services), traffic (routing, rate limits, budgets), behavior (service policies) — plus a 5-step rollout: enable previews → configure UC asset access → route via UAG → apply service policies → monitor usage. Matches this page's "Three Pillars" framing above; no new mechanics beyond what's already documented here. |
| [Tutorial: Implement guardrails on a model service with service policies](https://docs.databricks.com/aws/en/ai-gateway/moderate-tutorial) | Companion to the GitHub MCP tutorial above — attaches a service-policy guardrail to a Model Service |

---

## Feature Support Matrix (Serving Endpoints Path)

| Feature | External Models | FMAPI Pay-per-token | FMAPI Provisioned | Custom Models | Agents |
|---|---|---|---|---|---|
| Rate Limiting (QPM) | Yes | Yes | Yes | Yes | No |
| Rate Limiting (TPM) | Yes | Yes | Yes | No | No |
| Usage Tracking | Yes | Yes | Yes | Yes | No |
| Payload Logging | Yes | Yes | Yes | Yes | Yes |
| Guardrails (Safety) | Yes | Yes | Yes | Yes | No |
| Guardrails (PII) | Yes | Yes | Yes | Yes | No |
| Fallbacks | Yes | No | No | No | No |
| Traffic Splitting | Yes | No | Yes | Yes | No |

---

## Python SDK — Full Configuration

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.serving import (
    AiGatewayGuardrails,
    AiGatewayGuardrailParameters,
    AiGatewayGuardrailPiiBehavior,
    AiGatewayGuardrailPiiBehaviorBehavior,
    AiGatewayInferenceTableConfig,
    AiGatewayRateLimit,
    AiGatewayRateLimitKey,
    AiGatewayRateLimitRenewalPeriod,
    AiGatewayUsageTrackingConfig,
    FallbackConfig,
)

w = WorkspaceClient()

response = w.serving_endpoints.put_ai_gateway(
    name="my-endpoint",
    # --- Usage tracking ---
    usage_tracking_config=AiGatewayUsageTrackingConfig(enabled=True),
    # --- Inference tables ---
    inference_table_config=AiGatewayInferenceTableConfig(
        enabled=True,
        catalog_name="ml",
        schema_name="ai_gateway",
        table_name_prefix="gpt-4o-mini",
    ),
    # --- Rate limits ---
    rate_limits=[
        AiGatewayRateLimit(
            calls=100,
            key=AiGatewayRateLimitKey.ENDPOINT,
            renewal_period=AiGatewayRateLimitRenewalPeriod.MINUTE,
        ),
        AiGatewayRateLimit(
            calls=10,
            key=AiGatewayRateLimitKey.USER,
            renewal_period=AiGatewayRateLimitRenewalPeriod.MINUTE,
        ),
        AiGatewayRateLimit(
            calls=5,
            key=AiGatewayRateLimitKey.SERVICE_PRINCIPAL,
            principal="",
            renewal_period=AiGatewayRateLimitRenewalPeriod.MINUTE,
        ),
    ],
    # --- Guardrails ---
    guardrails=AiGatewayGuardrails(
        input=AiGatewayGuardrailParameters(
            invalid_keywords=["SuperSecretProject"],
            safety=True,
            pii=AiGatewayGuardrailPiiBehavior(
                behavior=AiGatewayGuardrailPiiBehaviorBehavior.BLOCK
            ),
        ),
        output=AiGatewayGuardrailParameters(
            safety=True,
            pii=AiGatewayGuardrailPiiBehavior(
                behavior=AiGatewayGuardrailPiiBehaviorBehavior.BLOCK
            ),
        ),
    ),
    # --- Fallbacks ---
    fallback_config=FallbackConfig(enabled=True),
)
```

---

## REST API

### PUT AI Gateway

```bash
PUT /api/2.0/serving-endpoints/{name}/ai-gateway
```

```json
{
  "usage_tracking_config": { "enabled": true },
  "inference_table_config": {
    "enabled": true,
    "catalog_name": "ml",
    "schema_name": "ai_gateway",
    "table_name_prefix": "gpt-4o-mini"
  },
  "rate_limits": [
    {
      "calls": 100,
      "key": "endpoint",
      "renewal_period": "minute"
    },
    {
      "calls": 10,
      "tokens": 1000,
      "key": "user",
      "renewal_period": "minute"
    }
  ],
  "guardrails": {
    "input": {
      "safety": true,
      "pii": { "behavior": "BLOCK" },
      "invalid_keywords": ["SuperSecretProject"]
    },
    "output": {
      "safety": true,
      "pii": { "behavior": "BLOCK" }
    }
  },
  "fallback_config": { "enabled": true }
}
```

### GET AI Gateway

```bash
GET /api/2.0/serving-endpoints/{name}/ai-gateway
```

Returns the same structure as the PUT response.

---

## Terraform

```hcl
resource "databricks_model_serving" "gpt_4o" {
  name = "gpt-4o-mini"

  ai_gateway {
    usage_tracking_config {
      enabled = true
    }

    inference_table_config {
      enabled           = true
      table_name_prefix = "gpt-4o-mini"
      catalog_name      = "ml"
      schema_name       = "ai_gateway"
    }

    # Endpoint-level ceiling
    rate_limits {
      calls          = 100
      key            = "endpoint"
      renewal_period = "minute"
    }

    # Per-user default
    rate_limits {
      calls          = 10
      tokens         = 1000
      key            = "user"
      renewal_period = "minute"
    }

    # Named service principal override
    rate_limits {
      calls          = 5
      key            = "service_principal"
      principal      = ""
      renewal_period = "minute"
    }

    guardrails {
      input {
        invalid_keywords = ["SuperSecretProject"]  # deprecated, use keyword filters
        safety           = true
        pii {
          behavior = "BLOCK"
        }
      }
      output {
        safety = true
        pii {
          behavior = "BLOCK"
        }
      }
    }

    fallback_config {
      enabled = true
    }
  }

  config {
    served_entities {
      name = "gpt-4o-mini"
      external_model {
        name     = "gpt-4o-mini"
        provider = "openai"
        task     = "llm/v1/chat"
        openai_config {
          openai_api_key = "{{secrets/llm_scope/openai_api_key}}"
        }
      }
    }
  }
}
```

### Terraform Argument Reference

| Block | Field | Type | Notes |
|---|---|---|---|
| `fallback_config` | `enabled` | bool | Round-robin on 429/5XX. External models only. Max 2 fallbacks. |
| `usage_tracking_config` | `enabled` | bool | Writes to `system.serving.endpoint_usage` |
| `inference_table_config` | `enabled` | bool | Payload logging to UC Delta |
| | `catalog_name` | string | Required when enabling |
| | `schema_name` | string | Required when enabling |
| | `table_name_prefix` | string | Optional naming prefix |
| `rate_limits` | `calls` | int | QPM (required) |
| | `tokens` | int | TPM (optional) |
| | `key` | string | `endpoint` / `user` / `user_group` / `service_principal` |
| | `principal` | string | Identity for user/group/SP scoped limits |
| | `renewal_period` | string | Only `minute` supported |
| `guardrails.input` / `.output` | `safety` | bool | Llama Guard 2-8b filter |
| | `pii.behavior` | string | `BLOCK` or `MASK` |
| | `invalid_keywords` | list | Deprecated |
| | `valid_topics` | list | Deprecated |

---

## Rate Limiting

### Precedence

1. **Endpoint limit** is the absolute ceiling; blocks ALL traffic when exceeded
2. **Custom limits** (per user/SP/group) override User Default
3. **User-specific** overrides group-specific
4. Multiple group membership: rate limited only when exceeding ALL group limits
5. If both QPM and TPM are set, the **more restrictive** applies

### Constraints

- Max **20 rate limits** per endpoint
- Max **5 group-specific** rate limits per endpoint
- Only `minute` renewal period supported
- Updates take up to **60 seconds** to propagate

---

## Guardrails — Two Implementations

Databricks ships **two distinct guardrail systems**. Pick by endpoint type:

| Aspect | **Legacy guardrails** (Serving Endpoints path) | **Unity AI Gateway guardrails** (Preview) |
|---|---|---|
| Endpoint type | Any model serving endpoint | Unity AI Gateway endpoints (sidebar) |
| Engine | Llama Guard 2-8b (safety), Presidio (PII), regex (keywords) | LLM-as-judge with configurable evaluator endpoint |
| Types | 3 fixed: safety, PII, keyword | 6 templates: PII redact, PII block, unsafe, jailbreak, hallucination, custom |
| Configuration | `PUT /api/2.0/serving-endpoints/{name}/ai-gateway` | `Guardrails` API on Unity AI Gateway endpoints |
| Customization | None (fixed categories) | Custom prompts up to 5,000 chars |
| Blocked response | HTTP 400 | HTTP 400 with `"Request blocked by input guardrail '<name>'."` |
| Streaming | Output guardrails  | Output guardrails  |

> **Migration path**: The legacy system stays for serving endpoint deployments. The new Unity AI Gateway guardrails are the strategic direction — richer types, custom policies, and explicit evaluator endpoints with audit trails per call.

---

## Guardrails — Legacy (Public Preview, Serving Endpoints)

### Safety Filtering

Uses **Llama Guard 2-8b**. Blocks violent crime, self-harm, hate speech, and other unsafe content. No customization of safety categories.

### PII Detection

Uses **Presidio**. US categories only: credit cards, emails, phone numbers, bank accounts, SSNs.

| Behavior | Effect |
|---|---|
| `BLOCK` | Reject the entire request |
| `MASK` | Redact PII and pass through |
| `NONE` | Disabled |

### Keyword Filters

Block requests containing specific strings on input and/or output.

> `invalid_keywords` and `valid_topics` are **deprecated** in the Terraform provider.

### Limitations

- Max batch size **16** when guardrails are enabled
- Output guardrails **** for embeddings or streaming
- Guardrails do not apply to function calling intermediate responses
- Not available on agent endpoints
- Text-to-image unsupported
- **Regional dependency**: guardrails require FMAPI pay-per-token availability in the region — not available in regions that lack pay-per-token FMAPI support (source: [Azure overview-serving-endpoints](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/overview-serving-endpoints))
- Route-optimized custom model endpoints do not support rate limiting or usage tracking; inference tables for route-optimized endpoints are in Public Preview

---

## Guardrails — Unity AI Gateway (Public Preview)

LLM-based guardrails that evaluate every request and response against an **evaluator endpoint** (recommended: `databricks-gpt-5-nano`). Each guardrail is one of six templates with a configurable Phase, Action, and Mode.

### Six Guardrail Templates

| Template | Action | Phase | Purpose |
|---|---|---|---|
| **PII Redaction** | Sanitize | Input/Output | Replace PII with placeholders (e.g., `[EMAIL]`) |
| **PII Blocking** | Block | Input/Output | Reject requests/responses containing PII |
| **Unsafe Content** | Block | Input/Output | Hate, harassment, violence, self-harm, sexual, weapons, extremism |
| **Jailbreak** | Block | Input | Instruction overrides, obfuscated payloads, role-play exploits, prompt extraction |
| **Hallucination** | Block | Output | Fabricated facts, invented stats, false citations, made-up credentials |
| **Custom** | Block or Sanitize | Input/Output | User-defined prompt up to 5,000 characters |

### Configuration Parameters

| Parameter | Values | Notes |
|---|---|---|
| `name` | up to 255 chars, `^[a-zA-Z0-9_ -]+$` | Required, surfaces in HTTP 400 error message |
| `phase` | `INPUT` or `OUTPUT` | When the guardrail runs |
| `action` | `BLOCK` or `SANITIZE` | Block returns 400; sanitize rewrites content |
| `mode` | `ENFORCE` (default) or `LOG` | `LOG` is dry-run — records decisions without blocking |
| `evaluator_endpoint` | Any AI Gateway endpoint | Must serve a supported API type |

### Per-Phase Capacity

- **3 blocking + 1 sanitizing** maximum per phase
- Within a phase, blocking guardrails run **in parallel**; sanitizing runs only if all blockers pass
- Per-call timeout: **30 seconds** (15s × 2 attempts)

### Supported APIs (Inference + Evaluator)

- OpenAI Chat Completions / MLflow Chat
- Anthropic Messages
- OpenAI Responses
- Gemini `generateContent`

Embeddings endpoints are ****.

### Custom Guardrail Prompt Authoring

- Define triggers narrowly with counterexamples
- Evaluator sees only extracted message text — no system prompt, history, tools, or attachments
- Do **not** specify output format; the gateway appends the JSON contract automatically
- For sanitize, specify the rewrite policy (e.g., mask credit cards as `XXXX-XXXX-XXXX-1234`)
- Use few-shot examples for ambiguous cases
- One prompt per concern (separate guardrails for PII, competitors, tone, etc.)

### Evaluator Request Shape

```json
{
  "model": "<evaluator endpoint>",
  "stream": false,
  "messages": [
    { "role": "system", "content": "<guardrail prompt>\n\n<output contract>" },
    { "role": "user", "content": "<extracted message text>" }
  ]
}
```

Blocking guardrails must return JSON with `flagged` (bool) and `confidence` (0.0–1.0). Sanitizing guardrails must return `flagged` and `sanitized_text`.

### Fail-Closed Behavior

Evaluator timeout, failure, or unparseable JSON **blocks the request**. Use `mode=LOG` to test new guardrails on production traffic without enforcing.

### Audit & Observability

- Enable usage tracking on both inference and evaluator endpoints — passing requests log `200`, blocked log `400`
- Enable inference tables on the **evaluator endpoint** to capture every guardrail call (raw response, latency, timestamp)
- Join inference tables across endpoints via shared `request_id`

### Permissions

- `CAN MANAGE` on **both** target and evaluator endpoints to configure guardrails
- System endpoints (`databricks-*` foundation models) bypass permission checks
- End users only need `CAN QUERY` on the target endpoint

### Limits

- 3 blocking + 1 sanitizing per phase (input and output count separately)
- **Streaming responses ** with output guardrails
- **Multi-choice responses** (`n > 1`) rejected with output guardrails
- Single-message evaluation only — cannot detect multi-turn or context-spanning attacks
- **Nested guardrails unsupported** — if the evaluator endpoint has its own guardrails, the gateway bypasses them

### Error Format

```
HTTP 400
"Request blocked by input guardrail '<name>'."
"Response blocked by output guardrail '<name>'."
```

The named guardrail in the error makes triage straightforward — log search by guardrail name to attribute blocks.

---

## Service Policies (ABAC)

Service Policies are attribute-based access control (ABAC) policies scoped to AI services in Unity AI Gateway. They are the broader governance mechanism of which guardrails are a built-in subset.

### Service Policies vs Guardrails

| Aspect | Guardrails | Service Policies |
|---|---|---|
| Scope | Content filtering on LLM input/output | Full interaction: content, tool calls, caller identity, context |
| Actions | Block or sanitize | Allow, deny, OR require human approval |
| Tool calls | Cannot govern tool calls | Can block out-of-policy tool calls |
| Human-in-the-loop |  | Supported — can require approval before proceeding |
| Where attached | Gateway endpoints | MCP Services and Model Services (UC securables) |
| Framing | Built-in service policies | Superset — includes guardrails and custom policies |

### Key concepts

- **Guardrails are built-in service policies** — the 6 guardrail templates (PII, unsafe content, jailbreak, hallucination, custom) are a predefined subset of the service policy system
- **Custom service policies** extend beyond content filtering — they can govern which tools an agent may invoke, enforce approval workflows, and make decisions based on caller attributes (user identity, group membership, SP)
- **Attached to UC securables** — service policies attach to MCP Services and Model Services (not just standalone endpoints), enabling governance at the asset level rather than the request path level

### Enforcement points and fail-closed behavior

Service policies evaluate at **two enforcement points**:

- **ON CALL** — before the service is invoked (evaluates the request/prompt and caller attributes)
- **ON RESULT** — after the service responds (evaluates the response, e.g. PII or unsafe content in output)

The model is **fail-closed**: a misconfigured or errored policy **blocks** the interaction rather than allowing it through. The built-in guardrail `system.ai.block_unsafe_content` denies interactions containing unsafe or harmful content; jailbreak and hallucination detection are likewise available as built-ins. Source: [Service policies for AI securables](https://docs.databricks.com/aws/en/data-governance/unity-catalog/service-policies/).

### Where to configure

Service policies are configured through the Unity AI Gateway UI (sidebar) and the AI Gateway API. For the latest schema and examples, see:

- [Service policies for AI securables](https://docs.databricks.com/aws/en/data-governance/unity-catalog/service-policies/)
- [Create and attach a service policy](https://docs.databricks.com/aws/en/data-governance/unity-catalog/service-policies/create-service-policy)
- [AI Gateway overview (Azure)](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/)

> **Relationship to MCP Services**: When you register an MCP server as an MCP Service (a UC securable), you attach service policies to control which tools are callable, by whom, and under what conditions. This is the primary mechanism for governing tool-level access in agentic workflows.

---

## Fallbacks

- Triggered on **429 or 5XX** errors
- **External models only** (GA path); Beta path supports all endpoint types
- Max **2 fallbacks** (GA); entities with 0% traffic serve as fallback-only
- Each entity tried once, sequentially
- First successful or last failed response is logged
- Routing attempts recorded in `routing_information` field (Beta system table)

---

## External Model Providers

| Provider Key | Service |
|---|---|
| `openai` | OpenAI and Azure OpenAI |
| `anthropic` | Anthropic |
| `cohere` | Cohere |
| `amazon-bedrock` | Amazon Bedrock (Anthropic, Cohere, AI21, Amazon) |
| `google-cloud-vertex-ai` | Google Vertex AI |
| `google-gemini-enterprise` | Google Gemini Enterprise (Auth: API key, GCP project ID, region) |
| `databricks-model-serving` | Other Databricks endpoints |
| `custom` | Any OpenAI-compatible provider |

### Provider Config Examples

```python
# --- OpenAI ---
external_model=ExternalModel(
    name="gpt-4o-mini", provider="openai", task="llm/v1/chat",
    openai_config=OpenAiConfig(
        openai_api_key="{{secrets/scope/openai_key}}"
    ),
)

# --- Azure OpenAI ---
external_model=ExternalModel(
    name="gpt-4o", provider="openai", task="llm/v1/chat",
    openai_config=OpenAiConfig(
        openai_api_type="azure",
        openai_api_base="https://my-resource.openai.azure.com",
        openai_api_version="2024-02-01",
        openai_deployment_name="gpt-4o-deploy",
        openai_api_key="{{secrets/scope/azure_key}}",
    ),
)

# --- Anthropic ---
external_model=ExternalModel(
    name="claude-sonnet-4", provider="anthropic", task="llm/v1/chat",
    anthropic_config=AnthropicConfig(
        anthropic_api_key="{{secrets/scope/anthropic_key}}"
    ),
)

# --- Amazon Bedrock (with UC Service Credential) ---
external_model=ExternalModel(
    name="claude-v2", provider="amazon-bedrock", task="llm/v1/completions",
    amazon_bedrock_config=AmazonBedrockConfig(
        aws_region="us-east-1",
        uc_service_credential_name="my_bedrock_cred",
        bedrock_provider="anthropic",
    ),
)

# --- Custom (OpenAI-compatible) ---
external_model=ExternalModel(
    name="custom-model", provider="custom", task="llm/v1/chat",
    custom_provider_config=CustomProviderConfig(
        custom_provider_url="https://api.provider.com/chat/completions",
        bearer_token_auth=BearerTokenAuth(
            token="{{secrets/scope/custom_token}}"
        ),
    ),
)
```

---

## Querying Endpoints

### OpenAI Client (works with both paths)

```python
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["DATABRICKS_TOKEN"],
    base_url="https://<workspace>.cloud.databricks.com/serving-endpoints"
)

response = client.chat.completions.create(
    model="my-endpoint-name",
    messages=[{"role": "user", "content": "What is Databricks?"}],
    extra_body={"usage_context": {"project": "project1", "team": "data-eng"}},
)
```

### Custom Request Tagging (Model Provider Services)

For Model Provider Services routes, pass custom tags via the `Databricks-Ai-Gateway-Request-Tags` header (JSON key-value pairs). These are logged to usage and inference tables for cost attribution:

```bash
curl -X POST "https://<workspace-url>/ai-gateway/openai/v1/chat/completions" \
  -H "Authorization: Bearer $DATABRICKS_TOKEN" \
  -H "Databricks-Model-Provider-Service: <catalog>.<schema>.<model-service-name>" \
  -H "Databricks-Ai-Gateway-Request-Tags: {\"project\": \"chatbot-v2\", \"team\": \"platform-eng\", \"priority\": \"high\"}" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'
```

These tags appear in `system.ai_gateway.usage` for filtering and cost analysis.

### Beta: Native Provider APIs

```python
# Anthropic native
import anthropic
client = anthropic.Anthropic(
    base_url="https://<ai-gateway-url>/anthropic/v1",
    default_headers={"Authorization": f"Bearer {DATABRICKS_TOKEN}"}
)

# Gemini native
from google import genai
client = genai.Client(
    http_options={"base_url": "https://<ai-gateway-url>/gemini/v1", ...}
)
```

### Model Provider Services — Managed Paths vs. Passthrough

When using Model Provider Services (UC securables for external providers), requests can route via **managed paths** (recommended) or **passthrough** (for unmapped provider endpoints):

| Aspect | Managed Paths | Passthrough |
|---|---|---|
| Examples | OpenAI chat completions, Anthropic messages, Gemini content gen | OpenAI files, batch endpoints, provider-specific APIs not in managed set |
| Usage tracking | Yes | No |
| Token-based rate limits | Yes | No |
| Service policies | Yes | No |
| Model access control | Yes | No |
| Inference tables | Yes | No |
| Selective header/parameter forwarding | Not applicable (stable endpoint) | Available via `forward_headers`, `forward_query_parameters` config |

> **Use managed paths by default.** Passthrough is a fallback for provider features not yet wrapped by Databricks. Every passthrough request loses observability and governance — operator beware.

Source: [Query model provider services](https://docs.databricks.com/aws/en/ai-gateway/query-model-provider-services)

---

## MCP Pillar — Governing Tool Servers Under UAG

Unity AI Gateway now treats Model Context Protocol (MCP) servers as a first-class governance target alongside LLM endpoints. The same primitives (permissions, audit logging, access control) apply across three MCP modes:

| MCP mode | What it is | Where to host | UAG primitives |
|---|---|---|---|
| **External MCP** | Govern access to an MCP server hosted outside Databricks | Vendor / external infra | Managed connections, network egress controls, audit logging |
| **Custom MCP** | Run your own MCP server as a Databricks App | Databricks Apps | App identity, OBO/M2M auth, UC access controls, payload logging |
| **Databricks-managed MCPs** | Native MCP servers (Genie, Vector Search, UC Functions) | Databricks workspace | Built-in UC permissions, default audit, no infra to manage |

### Why MCP under UAG matters

Before this unification, MCP governance was a separate topic — you had access control via UC, but observability, rate limiting, and request-level audit were ad-hoc. UAG bringing MCP into the same control surface means:

- **One audit trail** — every LLM call *and* every MCP tool invocation lands in the same observability story
- **One permissions model** — endpoint and MCP server ACLs share principals, groups, and SPs
- **One configuration surface** — operators don't toggle between two governance UIs

### Related Microsoft Learn topics (MCP pillar)

| Topic | What it covers |
|---|---|
| [Model Context Protocol (MCP) on Databricks](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/) | Overview of MCP server types on Databricks |
| [Install an external MCP server](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/external-mcp) | Connect to vendor-hosted MCP servers via managed connections |
| [Host a custom MCP server](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/custom-mcp) | Run an MCP server as a Databricks App |
| [Connect clients to Databricks MCPs](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/connect-clients) | Wire MCP clients to your Databricks-hosted MCPs |

For deeper coverage of MCP server types, auth, and patterns, see [`mcp/overview.md`](../mcp/overview.md), [`mcp/managed-mcp.md`](../mcp/managed-mcp.md), [`mcp/custom-mcp.md`](../mcp/custom-mcp.md), and [`mcp/external-mcp.md`](../mcp/external-mcp.md).

---

## Govern LLM Usage from Databricks Apps Agents

Agents authored with the Databricks Agent Framework and deployed to Databricks Apps can route all their LLM calls through Unity AI Gateway. The agent code points at a UAG endpoint instead of (or in addition to) a serving endpoint, and the gateway applies permissions, rate limits, guardrails, usage tracking, and inference logging on every call the agent makes.

### Wiring

```python
# Inside an Agent Framework agent deployed to Databricks Apps
from openai import OpenAI

# Use UAG endpoint as the OpenAI-compatible base URL
client = OpenAI(
    base_url="https://<workspace-host>/serving-endpoints/<uag-endpoint>",
    api_key=os.environ["DATABRICKS_TOKEN"],
)
# All calls flow through UAG: governed, logged, rate-limited, cost-attributed
```

The Apps-deployed agent inherits the gateway's:
- **Permissions** — only principals with access to the UAG endpoint can invoke
- **Rate limits** — per-user / per-group QPM and TPM enforcement
- **Guardrails** — input/output filtering applies before the call reaches the model
- **Usage tracking** — agent identity flows into `system.ai_gateway.usage`
- **Inference logging** — request/response pairs land in UC Delta tables
- **Cost attribution** — request tags (`usage_context`) carry through to the billable usage table

### Why this matters

This closes the last gap in the governance surface. Before: agents on Apps could call serving endpoints directly, and you got UC-level data governance but minimal LLM call-level audit. After: every LLM call from every Apps agent is governed through the same control point as coding agents and direct UAG callers.

See [Govern LLM usage from your agent (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/agent-framework/author-agent#ai-gateway).

---

## Coding Agent Integration (Sidebar gateway only)

Officially supported: **Cursor**, **Codex CLI**, **Gemini CLI**. **Claude Code** is supported and listed in the AI Gateway UI; setup follows the OpenAI-compatible base URL pattern.

> **Prefer [`ucode`](ucode.md) over the hand-wiring below.** ucode automates all of these configs plus OAuth, and adds per-launch workspace selection and BYO-provider routing. The manual recipes here remain the fallback for tools ucode doesn't launch (notably Cursor's inference, which ucode deliberately doesn't manage) and for CI/headless setups.

### Cursor

Settings → Cursor Settings → Models → API Keys.

1. Enable **Override OpenAI Base URL**: `https://<ai-gateway-url>/cursor/v1`
2. Paste Databricks PAT into **OpenAI API Key**
3. Click **+ Add Custom Model** and add the gateway endpoint name

> Currently only Databricks-created foundation model endpoints are supported as Cursor custom models.

### Codex CLI

Requires Codex CLI **0.118+** (`npm install -g @openai/codex@latest`).

Create `~/.codex/config.toml`:

```toml
profile = "default"

[profiles.default]
model_provider = "Databricks"

[model_providers.Databricks]
name = "Databricks AI Gateway"
base_url = "<ai-gateway-url>/codex/v1"
wire_api = "responses"

[model_providers.Databricks.auth]
command = "sh"
args = ["-c", "databricks auth token --host <workspace-url> --output json | jq -r '.access_token'"]
timeout_ms = 5000
refresh_interval_ms = 1800000
```

Authenticate once: `databricks auth login --host <workspace-url>`. Codex auto-refreshes tokens every 30 min via the auth command — no env var needed.

### Gemini CLI

Install nightly: `npm install -g @google/gemini-cli@nightly`.

Create `~/.gemini/.env`:

```
GEMINI_MODEL=databricks-gemini-2-5-flash
GOOGLE_GEMINI_BASE_URL=https://<ai-gateway-url>/gemini
GEMINI_API_KEY_AUTH_MECHANISM="bearer"
GEMINI_API_KEY=<databricks_pat_token>
```

### Claude Code

Use the standard Anthropic-compatible base URL pattern via the gateway's Anthropic native API surface (see "Beta: Native Provider APIs" below). Confirm the path in the AI Gateway UI for the registered Claude Code integration.

### Built-in dashboard

Select **View dashboard** from the AI Gateway page to provision a pre-configured AI/BI dashboard. Tracks usage/spend/metrics across all coding tools (Overview, Performance, Usage, Coding Agents tabs).

---

## OpenTelemetry Agent Telemetry → UC Delta

Coding agents can export OpenTelemetry **metrics and logs** directly to UC managed Delta tables via Databricks-hosted OTLP endpoints. Requires the OpenTelemetry-on-Databricks preview enabled.

### 1. Create UC tables (per agent or per team)

Two tables: `<prefix>_otel_metrics` and `<prefix>_otel_logs`. Both use `'otel.schemaVersion' = 'v1'` table property. Metrics table has full OTel schema (gauge, sum, histogram, exponential_histogram, summary structs). Logs table has standard OTel log fields (event_name, trace_id, span_id, body, attributes, severity, resource, instrumentation_scope).

```sql
CREATE TABLE <catalog>.<schema>.<prefix>_otel_metrics (...) USING DELTA
TBLPROPERTIES ('otel.schemaVersion' = 'v1');

CREATE TABLE <catalog>.<schema>.<prefix>_otel_logs (...) USING DELTA
TBLPROPERTIES ('otel.schemaVersion' = 'v1');
```

(See [Coding agent integration docs](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/coding-agent-integration-model-services) for full column lists.)

### 2. Configure agent env vars

```bash
OTEL_METRICS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://<workspace-url>/api/2.0/otel/v1/metrics
OTEL_EXPORTER_OTLP_METRICS_HEADERS="content-type=application/x-protobuf,Authorization=Bearer <pat>,X-Databricks-UC-Table-Name=<catalog>.<schema>.<prefix>_otel_metrics"
OTEL_METRIC_EXPORT_INTERVAL=10000

OTEL_LOGS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_LOGS_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://<workspace-url>/api/2.0/otel/v1/logs
OTEL_EXPORTER_OTLP_LOGS_HEADERS="content-type=application/x-protobuf,Authorization=Bearer <pat>,X-Databricks-UC-Table-Name=<catalog>.<schema>.<prefix>_otel_logs"
OTEL_LOGS_EXPORT_INTERVAL=5000
```

The `X-Databricks-UC-Table-Name` header routes the OTLP payload to a specific UC Delta table. Data lands within ~5 minutes.

> **Use case**: per-developer, per-team, or per-agent attribution beyond what `system.ai_gateway.usage` captures (custom span tags, tool-call traces, latency percentiles).

---

## System Tables

### Beta: `system.ai_gateway.usage`

Account-level, admin-only. Rich schema with 30+ columns.

| Key Columns | Type | Notes |
|---|---|---|
| `endpoint_id`, `endpoint_name` | STRING | Endpoint identifiers |
| `event_time` | TIMESTAMP | When request was received |
| `latency_ms`, `time_to_first_byte_ms` | LONG | Performance metrics |
| `destination_type`, `destination_model` | STRING | Which model served the request |
| `requester`, `requester_type` | STRING | Who made the request (user, SP, group) |
| `input_tokens`, `output_tokens`, `total_tokens` | LONG | Token counts |
| `token_details` | STRUCT | `cache_read_input_tokens`, `cache_creation_input_tokens`, `output_reasoning_tokens` |
| `status_code` | INT | HTTP response code |
| `routing_information` | STRUCT | Fallback attempts with priority, action, latency |
| `user_agent` | STRING | Client identifier (useful for coding agent tracking) |

### GA: `system.serving.endpoint_usage`

| Key Columns | Type | Notes |
|---|---|---|
| `databricks_request_id` | STRING | Databricks-generated request ID |
| `requester` | STRING | User/SP ID |
| `status_code` | INTEGER | HTTP status code |
| `request_time` | TIMESTAMP | Request timestamp |
| `input_token_count`, `output_token_count` | LONG | Token counts (0 for custom models) |
| `usage_context` | MAP | User-provided cost attribution metadata |
| `request_streaming` | BOOLEAN | Stream mode flag |
| `served_entity_id` | STRING | Join key to `served_entities` |

### GA: `system.serving.served_entities`

| Key Columns | Type | Notes |
|---|---|---|
| `served_entity_id` | STRING | Join key |
| `endpoint_name` | STRING | Endpoint name |
| `entity_type` | STRING | `EXTERNAL_MODEL`, `FOUNDATION_MODEL`, `CUSTOM_MODEL`, `FEATURE_SPEC` |
| `external_model_config` | STRUCT | e.g. `{Provider: OpenAI}` |
| `foundation_model_config` | STRUCT | Throughput settings |
| `task` | STRING | `llm/v1/chat`, `llm/v1/completions`, `llm/v1/embeddings` |

### Usage Tracking Join Query

```sql
SELECT
  eu.request_time,
  se.endpoint_name,
  se.entity_type,
  eu.requester,
  eu.input_token_count,
  eu.output_token_count,
  eu.status_code,
  eu.usage_context
FROM system.serving.endpoint_usage eu
JOIN system.serving.served_entities se
  ON eu.served_entity_id = se.served_entity_id
WHERE eu.request_time > current_timestamp() - INTERVAL 7 DAYS
ORDER BY eu.request_time DESC;
```

### Cost Attribution with `usage_context`

Pass arbitrary metadata for cost tracking (max 10 KiB):

```json
{
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 128,
  "usage_context": {
    "use_case": "customer-support",
    "project": "chatbot-v2",
    "team": "platform-eng",
    "priority": "high"
  }
}
```

---

## Cost Observability

Unity AI Gateway exposes cost analysis as a dedicated topic with two complementary surfaces: the **billable usage system table** for SQL-driven cost queries and the **pre-built UAG usage dashboard** for visual analysis.

### Billable usage system table

Cost attribution joins three system tables:

| Table | Purpose |
|---|---|
| `system.billing.usage` | Dollar-denominated billable usage (DBUs × workspace tier × SKU price) |
| `system.ai_gateway.usage` | UAG call-level metadata (endpoint, principal, tokens, request tags) |
| `system.serving.served_entities` | Resolves served-entity IDs to model names / provider |

```sql
-- Cost by UAG endpoint, principal, and tag
SELECT
  g.endpoint_name,
  g.principal_id,
  g.usage_context['team'] AS team,
  SUM(b.usage_quantity * b.list_price) AS dollars
FROM system.billing.usage b
JOIN system.ai_gateway.usage g
  ON b.usage_metadata.endpoint_name = g.endpoint_name
  AND b.usage_date = g.request_date
WHERE b.sku_name LIKE '%AI_GATEWAY%'
GROUP BY 1, 2, 3
ORDER BY dollars DESC;
```

### UAG usage dashboard (pre-built)

Select **View dashboard** from the AI Gateway page to provision a pre-configured AI/BI dashboard. Four tabs:

| Tab | What it shows |
|---|---|
| **Overview** | Total spend, top endpoints, top principals, trend lines |
| **Performance** | Latency p50/p95/p99, error rate, provider availability |
| **Usage** | Call volume by endpoint, model, principal, request tag |
| **Coding Agents** | Cursor / Codex / Gemini / Claude Code spend, per-user breakdown |

The dashboard is owned by the principal who provisions it and can be shared like any AI/BI dashboard — no separate ACL system.

### Cost analysis dimensions

| Dimension | How to filter |
|---|---|
| **By endpoint** | `WHERE endpoint_name = '<name>'` |
| **By principal** | `WHERE principal_id = '<user-or-sp>'` |
| **By team / app** | `WHERE usage_context['team'] = '<team>'` (requires tagging at call time) |
| **By model / provider** | Join `system.serving.served_entities` |
| **By time window** | `WHERE request_date BETWEEN ...` |

> See [Monitor Unity AI Gateway cost (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/cost-observability) for the complete query catalog and dashboard provisioning steps.

---

## Inference Tables

### GA Path (Serving Endpoints)

- Payload limit: **1 MiB** per request/response
- Delivery: within **1 hour**
- Schema: `request_date`, `databricks_request_id`, `client_request_id`, `request_time`, `status_code`, `sampling_fraction`, `execution_duration_ms`, `request`, `response`, `served_entity_id`, `logging_error_codes`, `requester`
- Agent endpoints create 3 tables: Payload, Request logs, Assessment logs
- **Do not modify** inference tables after creation (no schema changes, renaming, or deletion)
- Cannot specify existing tables

### Beta Path

- Payload limit: **10 MiB**
- Delivery: typically **within minutes**
- Logs may not be populated for 401, 403, 429, 500 errors
- Need `CREATE TABLE`, `USE CATALOG`, `USE SCHEMA` permissions

---

## Gotchas

1. **Two systems, different tables**: the UAG path uses `system.ai_gateway.usage`, the serving-endpoints path uses `system.serving.endpoint_usage`. Both are GA. Do not confuse them. ("Beta table" / "GA table" shorthand from earlier revisions of this page is retired — the split is by path, not by release state.)
2. ~~**Beta has no guardrails**~~ **Corrected 2026-08-05**: guardrails/service policies are GA on the UAG path. The old claim that safety/PII filtering existed only on the serving-endpoints path is wrong post-GA. Both paths have guardrails; they differ in implementation (UAG uses model-evaluated service policies, serving endpoints uses Presidio-backed safety/PII/keyword filters).
3. **Output guardrails break streaming**: Output guardrails are  for streaming or embeddings.
4. **Batch size cap**: Max 16 items per batch when guardrails are enabled.
5. **PII = US only**: Presidio detects US formats (credit cards, SSN, phone). Non-US PII is not covered.
6. **Safety = Llama Guard, no customization**: Cannot change safety categories or thresholds.
7. **Fallback limits**: Max 2 fallbacks on GA path. External models only.
8. **Config propagation delay**: Most changes: 20-40 seconds. Rate limits: up to 60 seconds. Beta endpoints: up to 1 minute.
9. **Deprecated Terraform fields**: `invalid_keywords` and `valid_topics` in guardrails are deprecated.
10. **Inference tables are immutable**: Do not alter schema, rename, or delete after creation.
11. **Token estimation**: When provider does not return token counts, AI Gateway estimates as `(text_length+1)/4`.
12. **Only account admins** can query system tables.
13. **`model` field required**: AI Gateway `/mlflow/v1/chat/completions` requires a `model` field containing the **route name**, not the underlying model name.
14. **Coding agent integration**: Sidebar gateway only. Claude Code is officially supported and surfaces in the AI Gateway UI alongside Cursor/Codex/Gemini.
20. **Codex CLI auth**: 0.118+ replaces the old `DATABRICKS_TOKEN` env var with an `auth.command` that shells out to `databricks auth token`. CLI-managed token rotation, no manual refresh.
21. **OTel agent table routing**: The `X-Databricks-UC-Table-Name` header is the routing primitive. Misnamed table = silent drop. Logs delayed up to 5 minutes.
22. **Custom APIs are first-class**: The sidebar gateway can govern arbitrary external APIs (not just LLMs) under the same access controls, rate limits, and inference logging — useful for putting governance in front of internal HTTP services.
15. **`invalid_keywords` silently dropped**: The PUT AI Gateway API accepts `invalid_keywords` without error, but the field is NOT stored or enforced. GET returns `null`. Do not rely on keyword filtering (deprecated since ~2025).
16. **Fallback requires multi-entity endpoint**: Fallback is entity-level within a single endpoint (multiple served entities), NOT across separate endpoints. Create 2+ entities with traffic split (e.g., 100/0) and enable fallback.
17. **Rate limit `calls` and `tokens` are mutually exclusive**: Each `AiGatewayRateLimit` entry must specify EITHER `calls` OR `tokens`, not both. SDK raises `InvalidParameterValue` if both are set. Use separate entries for QPM and TPM.
18. **Inference table prefix is immutable per endpoint**: Once an inference table is created with a prefix, that prefix cannot be reused on a recreated endpoint. Use a different prefix or drop the table first.
19. **Azure OpenAI regional vs custom domain**: Use the regional endpoint URL (`https://<region>.api.cognitive.microsoft.com`) for `openai_api_base` unless custom domains are explicitly enabled on the Azure OpenAI resource.
23. **MCP Services are UC securables**: MCP servers (Google Drive, Jira, Slack, GitHub, and custom) are now registered as MCP Services via the "Connect agents to third-party tools with MCP Services" flow in UAG — not solely through UC HTTP connections. Rate limits and service policies attach at this layer.
24. **Hard spend caps stop traffic, but only approximately**: Budget thresholds support two actions: "Send alert" (email notification, access continues) and "Block usage" (the user is prevented from making further requests through UAG and sees a budget-exhausted message; access resumes on budget reset or an admin threshold increase). **Correction (2026-08-05): "Block usage" is not Genie-only.** It applies with **Unity AI Gateway selected as the resource type**. The earlier Genie-only claim came from a 2026-07-14 UI observation where the Block option was absent for a model-service budget; GA has overtaken it, so re-verify in the UI rather than trusting the old note. The real caveat is different and the docs state it plainly: enforcement uses a **near-real-time cost estimate**, so actual spend can overshoot the threshold before blocking engages — "do not use this feature as a way to ensure an absolute spend cap on final billed amounts." For a firm ceiling, pair budgets with rate limits. Budgets track spend at the underlying UC model-service level; spend rolls up correctly regardless of which API surface (mlflow-format, native provider API) was used to reach the model. Source: [Manage budgets](https://docs.databricks.com/aws/en/ai-gateway/budgets).
26. **Budgets are account-level, not per-workspace or per-model**: a Budget shown on a model service's "Budgets" tab is a view into an account-console-managed budget (`Usage > Budgets`) that happens to cover that workspace — scope (workspaces/resource types/tags) can't be edited after creation.
27. **Budgets only track pay-per-token and ai_query (batch) inference**: Provisioned throughput and external-model inference are NOT tracked by Unity AI Gateway budgets. Do not rely on budget caps to limit provisioned-throughput spend. Source: [Manage budgets](https://docs.databricks.com/aws/en/ai-gateway/budgets).
28. **Budget scale limits**: Max 4 shared thresholds per budget, max 20 per-user overrides per budget, max 1,000 budgets per account. Spend amounts may vary across budget alert emails, the budget details page, and system tables due to different update frequencies -- budget enforcement itself uses near real-time tracking. Source: [Manage budgets](https://docs.databricks.com/aws/en/ai-gateway/budgets).
29. **Legacy guardrails have a regional dependency**: The AI Guardrails moderation service (safety and PII) on serving endpoints depends on FMAPI pay-per-token availability. Guardrails are not available in regions that do not support FMAPI pay-per-token. Source: [AI Gateway for serving endpoints](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/overview-serving-endpoints).
30. **Route-optimized custom endpoints do not support rate limiting or usage tracking**: If you deploy a route-optimized custom model serving endpoint, AI Gateway rate limits and usage tracking are silently unavailable. Only non-route-optimized custom endpoints support those features. Inference tables for route-optimized endpoints are in Public Preview. Source: [AI Gateway for serving endpoints](https://learn.microsoft.com/en-us/azure/databricks/ai-gateway/overview-serving-endpoints).
25. **Service policies vs guardrails — they are not the same**: Guardrails are built-in service policies (content filtering only). Custom service policies can govern tool calls and trigger human-approval workflows — guardrails cannot. Attach service policies to MCP Services and Model Services (UC securables) for tool-level governance.
31. **The Model Service surface and the legacy `serving-endpoints` API do NOT sync**: an endpoint exposes two independent governance surfaces — the new **Model Service** UI (AI Gateway > Models > `<endpoint>` > *Governance setup*, "N of 4 tasks done") and the legacy `PUT /api/2.0/serving-endpoints/<name>/ai-gateway` API. Configuring an inference table or rate limit through the legacy API creates a real resource but the Model Service panel still shows "Set up", leaving two competing configs. Configure governance through the **Model Service** surface. Corollary: rate limits and policies set via Model Service do **not** appear in a legacy `GET .../ai-gateway` config read — **verify behaviorally** (send traffic and observe 429 / `REQUEST_BLOCKED_BY_POLICY`), never by reading config. Hands-on, 2026-08.
32. **New-surface guardrails are LLM-judge classifiers — there is no keyword-match option**: the templates (PII Blocking, Unsafe Content, Jailbreak, Hallucination, Custom) are all model-evaluated. The keyword filters documented under *Guardrails — Legacy* above exist only on the legacy serving-endpoints path. For a deterministic test of the new surface, built-in **PII Blocking** is the most reliable (e.g. SSN `123-45-6789`, card `4111 1111 1111 1111`). Distinguish a real block (4xx with `REQUEST_BLOCKED_BY_POLICY` and a `phase`) from a polite model refusal (200 with text) — the latter is not enforcement. Hands-on, 2026-08.
33. **Model Provider Services (BYO key) lose budgets entirely, and passthrough loses much more**: routing to an external provider via a UC Model Provider Service keeps usage tracking, inference tables, rate limits, and service policies, but "spend from model provider services is not tracked in budgets" — no notifications, alerts, or hard caps. Separately, enabling **"Forward all URL paths"** (passthrough for unmapped provider endpoints) means "usage token and cost tracking, token-based rate limits, model access control, and service policies do not apply to passthrough requests." Only managed paths are fully governed. Source: [Query model provider services](https://docs.databricks.com/aws/en/ai-gateway/query-model-provider-services), [Model provider services](https://docs.databricks.com/aws/en/ai-gateway/model-provider-services).

---

## When to Use Which Gateway

Not all traffic needs a gateway. The wrong choice breaks OBO token chains or adds unnecessary hops.

| Traffic pattern | Gateway needed? | Why |
|---|---|---|
| Internal Databricks (agent → Genie, Vector Search, MCP) | **No gateway** | OBO token chain must not be ; UC governs at the data plane |
| LLM endpoint governance | **Databricks AI Gateway** | Rate limits, guardrails, usage tracking, fallback routing |
| Outbound to external services | **UC Connections + SNP** | `USE CONNECTION` authorization + serverless network policy |
| Inbound from external clients | **External API Gateway** | Auth translation, rate limits, API versioning |

> **Genie caveat (2026-09-11, field guidance)**: UAG does not yet govern Genie Spaces (see Gotcha #34), so the "LLM endpoint governance → Databricks AI Gateway" row does not currently apply to a Genie path. Until UAG-for-Genie ships, native Databricks content controls are unavailable on the Genie leg. An **inbound external gateway** in front of the calling app can serve as an interim prompt-injection and rate-limit control, but only if it preserves the user's bearer token unchanged — terminating and re-authenticating with the gateway's own credential collapses per-user identity and disables UC row filters/column masks. Data-leakage protection on Genie stays a UC data-plane concern regardless of any proxy.

For detailed patterns and sequence diagrams, see [Applied AI Governance — AI Gateway Patterns](https://github.com/bhavink/applied-ai-governance/blob/main/tool-governance/ai-gateway-patterns.md).

---

---

## Related

- [`ai/omnigent.md`](omnigent.md) — meta-harness for coding agents; on the managed deployment, model calls route through this same AI Gateway
- [`ai/ucode.md`](ucode.md) — Databricks' lighter coding-agent launcher, same per-harness AI Gateway routing
- [`ai/model-serving.md`](model-serving.md) — Endpoint creation, FMAPI, provisioned throughput, external models
- [`ai/endpoint-telemetry.md`](endpoint-telemetry.md) — OTel-based telemetry to UC Delta
- [`mcp/overview.md`](../mcp/overview.md) — MCP server types on Databricks (now governed under UAG)
- [`mcp/managed-mcp.md`](../mcp/managed-mcp.md) — Databricks-managed MCPs (Genie, Vector Search, UC Functions)
- [`mcp/custom-mcp.md`](../mcp/custom-mcp.md) — Custom MCP server hosted on Databricks Apps
- [`mcp/external-mcp.md`](../mcp/external-mcp.md) — External MCP server via managed connections
- [`governance/unity-catalog.md`](../governance/unity-catalog.md) — Grants and privileges for securing endpoints
- [`auth/overview.md`](../auth/overview.md) — Auth patterns for calling endpoints (OBO, M2M, PAT)
