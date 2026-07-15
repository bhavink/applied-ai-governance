# AI Gateway Governance: Plug-and-Play Guardrails

A recipe for enforcing AI Gateway guardrails across all endpoints and workspaces with no opt-out.

---

## The Pattern

**Policy as Data**: guardrail rules stored in a UC Delta table, applied to every endpoint via the AI Gateway API, enforced continuously by a scheduled job.

```
Define (UC table) → Apply (API) → Serve (guardrails active) → Capture (logs) → Score (MLflow) → Enforce (drift fix) → Attest (dashboard)
```

## Prerequisites

- Databricks workspace with Unity Catalog enabled
- AI Gateway enabled (GA for serving endpoints, Beta for standalone)
- Account admin access for system tables
- FMAPI pay-per-token endpoints (no external keys needed)

## Step 1: Create the Policy Table

Store guardrail policy in a governed UC Delta table. One row per scope (global, team, endpoint).

**Schema:**

| Column | Type | Purpose |
|---|---|---|
| `policy_id` | STRING | Primary key |
| `scope` | STRING | `global`, `team:<group>`, `endpoint:<name>` |
| `safety_enabled` | BOOLEAN | Llama Guard safety filter |
| `pii_behavior` | STRING | `BLOCK`, `MASK`, or `NONE` |
| `blocked_keywords` | ARRAY\<STRING\> | Keyword blocklist |
| `rate_limit_qpm_endpoint` | INT | Queries per minute (endpoint ceiling) |
| `rate_limit_qpm_user` | INT | Queries per minute (per user default) |
| `updated_by` | STRING | `current_user()` |
| `updated_at` | TIMESTAMP | Last modified |
| `version` | INT | Monotonically increasing |

**Key design decisions:**
- Governed by UC ACLs: only `ai-gov-admins` can write
- Versioned: every change creates a new version
- Queryable: any dashboard or Genie space can read it
- Team-scoped rows override global defaults within bounds

## Step 2: Apply Guardrails via API

A function reads the policy table and calls the AI Gateway REST API for each endpoint.

**API:** `PUT /api/2.0/serving-endpoints/{name}/ai-gateway`

**Payload structure:**

```json
{
  "usage_tracking_config": { "enabled": true },
  "inference_table_config": {
    "enabled": true,
    "catalog_name": "<catalog>",
    "schema_name": "<schema>",
    "table_name_prefix": "<prefix>"
  },
  "rate_limits": [
    { "calls": 100, "key": "endpoint", "renewal_period": "minute" },
    { "calls": 10, "key": "user", "renewal_period": "minute" }
  ],
  "guardrails": {
    "input": { "safety": true, "pii": { "behavior": "BLOCK" } },
    "output": { "safety": true, "pii": { "behavior": "BLOCK" } }
  }
}
```

**One function, every endpoint**: the same policy is applied regardless of model type (FMAPI, external, custom, agent).

## Step 3: Enable Observability

| Data source | What it captures | Scope |
|---|---|---|
| **Inference tables** | Full request/response payloads | Per endpoint |
| **System tables** (`system.serving.endpoint_usage`) | Token counts, requester, status codes, `usage_context` | Account-level (all workspaces) |
| **System tables** (`system.serving.served_entities`) | All endpoints, entity types, workspace_id | Account-level |
| **MLflow tracing** | Spans, tool calls, retrieval steps | Per experiment |
| **MLflow scorer assessments** | Safety, PII, jailbreak, secrets detection | Attached to traces |

**Key finding**: `served_entities` and `endpoint_usage` both have `workspace_id` and `account_id` columns. Cross-workspace visibility is native, no federation needed.

## Step 4: Register MLflow Scorers

Two tiers of scoring:

**Code-based (every trace, zero LLM cost):**
- PII detection (regex: credit cards, SSNs, emails, phone numbers)
- Secret detection (regex: API keys, AWS keys, GitHub PATs)
- Jailbreak detection (pattern matching: "ignore all previous", "you are now DAN")

**LLM-based (sampled):**
- MLflow built-in: Safety, RetrievalGroundedness, Guidelines
- Third-party (batch eval only): DeepEval AnswerRelevancy, RAGAS FactualCorrectness

**Production monitoring**: code-based scorers register with `sample_rate=1.0`, LLM scorers at `0.3-0.5`.

**Important**: third-party scorers (DeepEval, RAGAS, Phoenix) cannot be `.register()` for production monitoring. They work only with `mlflow.genai.evaluate()`.

## Step 5: Continuous Enforcement

A scheduled job (every 5 minutes) that:

1. Queries `system.serving.served_entities` to find ALL endpoints across ALL workspaces
2. For each endpoint, calls `GET /api/2.0/serving-endpoints/{name}/ai-gateway` to check config
3. Compares against the UC policy table
4. If non-compliant: re-applies guardrails via `PUT` API
5. Logs every action to an `enforcement_audit` UC table

**Enforcement audit schema:**

| Column | Type | Purpose |
|---|---|---|
| `endpoint_name` | STRING | Which endpoint |
| `action` | STRING | `applied`, `tamper_detected`, `re_applied`, `apply_failed` |
| `policy_version` | INT | Which policy version was enforced |
| `details` | STRING | What was wrong, what was fixed |
| `actor` | STRING | `enforcement_job` or `user@email` |
| `event_time` | TIMESTAMP | When |

## Step 6: Dashboards and Genie

**Per-workspace dashboard (4 pages):**
- Estate Overview: KPIs (endpoints, tamper attempts)
- Threat Insights: block categories (pie), detected threats (bar), prompt previews (table)
- Audit Trail: enforcement actions by type, detailed log
- Policy: current guardrail config

**Account-level dashboard (5 pages):**
- Account Estate: endpoints by type, by workspace
- Compliance Detection: guardrail status distribution, unguarded endpoints
- Traffic & Cost: daily trends, top requesters, cost attribution
- CISO Safety: block rate KPIs, per-endpoint block rates
- Enforcement Audit: actions by type, detailed log

**Genie space**: exposes the account-level views for natural-language queries.

## The 4 Governance Levers

| Lever | Foundation Models | External Models | Custom Models | Agents |
|---|---|---|---|---|
| **UC Permissions** | `system.ai` EXECUTE | Secret scope ACLs | EXECUTE grant on model | EXECUTE grant on model |
| **Rate Limits** | QPM=0 disables | Per user/SP/group | Per user/SP/group | Per user/SP/group |
| **Egress Controls** | N/A (system endpoint) | Key management | N/A | N/A |
| **Runtime Guardrails** | AI Gateway | AI Gateway | AI Gateway | AI Gateway + MLflow scorers |

### Guardrails vs Service Policies — Not the Same Lever

These two controls address different problems and operate at different layers:

**Guardrails** (configured on the AI Gateway) govern content: what enters the model and what it returns. Safety filters, PII detection, topic restrictions. Applied at the serving endpoint level.

**Service policies** (configured on MCP Services) govern access: which principals can call which tools, and whether human approval is required before a tool executes. Applied at the MCP Service level, before the request reaches the endpoint.

Use guardrails to enforce what the model can say. Use service policies to enforce who can do what. Both can be active simultaneously — a call must pass service policy checks before content guardrails even apply.

## FM UC Permissions (Preview)

All Databricks-hosted foundation models become UC securables in `system.ai`.

- `REVOKE EXECUTE` on a model disables it org-wide (PPT, PT, Batch)
- 1P products (Genie, Assistant, Agent Bricks, AI Functions) are NOT governed
- `AI_QUERY()` IS governed (calls user-owned endpoints)
- Position as last-resort lever for legal/regulatory allow/ban requirements
- Enroll: `go/fm-permissions/enroll` via Salesforce preview portal

## Where Things Live

| Artifact | Location | Maintained by |
|---|---|---|
| Reference docs | `fieldkit/databricks/ai/ai-gateway.md` | Fieldkit weekly auto-refresh |
| Presentation | `applied-ai-governance/presentations/02-unity-ai-gateway.html` | Manual (refresh when major features ship) |
| This recipe | `applied-ai-governance/tool-governance/ai-gateway-governance-recipe.md` | Manual |
| Notebooks | Workspace (`adb-aigov`) + `0-dayjob/ai-gateway-governance/` backup | Weekly validation job |
| Dashboards | Workspace (`adb-aigov`) Lakeview | Live (queries run on refresh) |
| Genie space | Workspace (`adb-aigov`) | Live (queries run on ask) |

## Related

- [AI Gateway fieldkit reference](https://github.com/bhavink/fieldkit/blob/main/databricks/ai/ai-gateway.md)
- [Third-party scorers reference](https://github.com/bhavink/fieldkit/blob/main/databricks/ai/third-party-scorers.md)
- [MLflow production monitoring](https://github.com/bhavink/fieldkit/blob/main/databricks/ai/production-monitoring.md)
- [UC OTel tracing](https://github.com/bhavink/fieldkit/blob/main/databricks/ai/mlflow-tracing.md)
