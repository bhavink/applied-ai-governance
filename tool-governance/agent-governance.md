<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: ai/agent-framework.md, ai/agent-bricks.md, ai/agent-tool.md, ai/uc-functions.md, ai/genie.md, ai/vector-search.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/generative-ai/agent-framework/
    - https://docs.databricks.com/aws/en/generative-ai/agent-bricks/
  This file is auto-prepared and human-reviewed before publish.
-->

# Agent Governance Framework

> **TL;DR**: A governed AI system requires controls at six distinct layers. Agents must have explicit SP identities — never inherited user shells. OBO propagates the user token end-to-end; M2M runs as the SP. Every tool an agent calls — UC function, retriever, sub-agent, or external connection — carries its own auth model, and the governance model must be chosen deliberately per tool rather than assumed. Audit requires joining MLflow traces (application plane) + `system.access.audit` (data plane).

---

## The Six Enforcement Layers

Every AI architecture decision maps to one or more of these layers. Never accept a design that relies on a single layer.

```
+-------------------------------------------------------------+
|  LAYER 6: AUDIT & OBSERVABILITY                             |
|  system.access.audit + MLflow traces + application logs     |
+-------------------------------------------------------------+
|  LAYER 5: EXECUTION BOUNDARY                                 |
|  Model Serving · Databricks Apps · serverless compute       |
+-------------------------------------------------------------+
|  LAYER 4: OUTBOUND CONTROL                                   |
|  UC Connections · Serverless Network Policies (SNP)         |
+-------------------------------------------------------------+
|  LAYER 3: DATA GOVERNANCE                                    |
|  Row Filters · Column Masks · ABAC · UC Functions (write)   |
+-------------------------------------------------------------+
|  LAYER 2: PERMISSION MODEL                                   |
|  Unity Catalog privileges · least-privilege SP grants        |
+-------------------------------------------------------------+
|  LAYER 1: IDENTITY                                           |
|  Agent SP identity · User OBO · Token federation             |
+-------------------------------------------------------------+
```

---

## Governing Principles (Non-Negotiable)

Design constraints, not guidelines. Any proposed agent architecture must satisfy all of them.

| # | Principle | In practice |
|---|---|---|
| P1 | **Identity is never assumed** | Every agent, user, and service has an explicit, verifiable identity. No implicit roles from environment. |
| P2 | **Least privilege by default** | New principals start with zero access. Access is granted explicitly, scoped to what is needed. |
| P3 | **Platform enforces, code documents** | Access controls live in UC (row filters, grants), not in application WHERE clauses. App code cannot be the only enforcement point. |
| P4 | **Every action leaves a record** | Any operation on data, any agent invocation, any external service call must appear in an audit log the agent cannot modify. |
| P5 | **Write operations are gated** | No agent has raw INSERT/UPDATE/DELETE. All writes go through UC Functions that enforce invariants and record attribution. |
| P6 | **Credentials never touch agent code** | API keys and secrets live in UC Connections or Databricks Secrets — never in source code, never in prompts. |
| P7 | **External access is governed at the edge** | Outbound calls to CRM, email, HRM, or any external system go through a defined, audited proxy. Agents do not hold raw API credentials. |
| P8 | **OBO preserves the user chain** | When an agent acts on behalf of a user, the user's identity flows to every downstream data access — including through sub-agents and tool calls. The user's permissions, not the agent's, govern what data is returned. |
| P9 | **Capability matches declared intent** | An agent deployed for "read-only deal analysis" must be technically incapable of write operations — not just conventionally restricted. |
| P10 | **Workspace isolation is zero-trust** | New workspace members receive no access by default. The default group carries no entitlements. |

---

## Agent Identity: One SP per Capability Boundary

**The problem**: When a developer runs an agent locally, the agent inherits the developer's shell identity. There is no audit record showing "an agent did this" vs "the developer typed this."

**The answer**: Every deployed agent is a Service Principal. One SP per capability boundary — not one SP per application. An agent that does read-only analysis and an agent that submits write operations must have different SPs.

**Correctly scoped SP example** (read-only sales agent):

```
sales-agent-sp (UUID: abc-123)
  USE CATALOG     → catalog
  USE SCHEMA      → catalog.sales
  USE SCHEMA      → catalog.functions
  SELECT          → catalog.sales.opportunities
  SELECT          → catalog.sales.sales_reps
  EXECUTE         → catalog.functions.get_rep_quota
  EXECUTE         → catalog.functions.recommend_next_action
  CAN_USE         → SQL warehouse (for M2M queries)
  CAN_QUERY       → serving endpoint (for model calls)
  USE CONNECTION  → catalog_crm_conn
```

That is the complete grant set. Nothing else.

**Verification**:

```sql
SHOW GRANTS ON CATALOG catalog TO `<agent-sp-uuid>`;
SHOW GRANTS ON SCHEMA catalog.sales TO `<agent-sp-uuid>`;
```

If this returns anything beyond `USE CATALOG`, `USE SCHEMA`, and specific object-level grants, the SP is over-privileged.

---

## Tool Governance for Agents

An agent's risk surface is really the sum of its tools. Each tool type below carries a distinct auth model, a distinct governance mechanism, and a distinct blast radius if misconfigured — treat tool selection as a governance decision, not just an implementation detail.

### Tool Types and Auth Models

| Tool type | What it does | Auth model | Governance mechanism |
|---|---|---|---|
| **Managed MCP server** | Built-in MCP for UC Functions, Vector Search, UC discovery, Genie | OBO or SP (automatic) | UC privileges |
| **External connection tool** | Third-party MCP servers (e.g., ticketing or search systems) via UC HTTP connection | `USE CONNECTION` + stored credential | `USE CONNECTION` privilege |
| **Custom MCP server** | Your own MCP server for internal APIs | Custom (your server's auth) | Code-level + connection privilege |
| **UC Function** | Executes a SQL/Python function registered in Unity Catalog | Caller's identity (OBO) or SP | `EXECUTE` privilege on the function |
| **Retriever tool (Vector Search)** | Queries a Vector Search index for RAG | SP (M2M) or OBO | `SELECT` on the index and its source table |
| **Code interpreter** (`system.ai.python_exec`) | Runs dynamic Python for calculation and data wrangling | Caller's identity (OBO) or SP | `EXECUTE` on `system.ai.python_exec` |
| **Agent-as-tool** | Calls another deployed agent (sub-agent) as a tool | Inherits parent's auth | Sub-agent's own serving-endpoint grants |
| **Custom Python function** | Arbitrary Python code wrapped as a tool | Defined in code (SP, OBO, or custom) | Code-level only — no UC privilege check on the tool itself |

Prefer the more governed options higher in this table: a managed or external MCP tool gets standardized schema validation and auth delegation for free, where a custom Python function requires you to implement access control, credential handling, and audit logging yourself.

### OBO vs M2M, by Tool

Whether a tool call runs as the calling user (OBO) or as the agent's own identity (M2M) determines which grants apply and what the user sees:

- **UC Functions**: `current_user()` inside the function reflects the caller under OBO, or the SP identity under M2M. `EXECUTE` privilege gates who can call the function at all.
- **Genie**: Always OBO — the caller's token executes the generated SQL, so row filters and column masks on the underlying tables apply automatically. There is no M2M mode for Genie query execution.
- **Vector Search**: M2M (the serving endpoint's SP) by default, requiring `SELECT` on the index and its source table for that SP. Pass the user's token explicitly in the request to run a query as the calling user instead, so row-level controls on the source table apply to that user.

**Design pattern for group-based checks**: `is_member('group')` evaluates the *workspace*-group membership of the identity actually executing the SQL — which, under Genie OBO or any service-mediated execution path, may be a service context rather than the human user. For access checks that must resolve reliably to the human regardless of execution path, prefer `current_user()` joined against an allowlist table over `is_member()`:

```sql
CREATE FUNCTION main.access.region_filter(region STRING)
RETURNS BOOLEAN
RETURN current_user() IN (
  SELECT email FROM main.access.region_allowlist WHERE access_region = region
);
```

If your organization manages groups at the account level, mirror the ones used for row-filter checks into workspace groups, or standardize on the `current_user()` + allowlist pattern above so the check does not depend on which layer executed the query.

### UC Functions as Governed Tools

UC Functions are the most auditable tool type — they run inside the UC execution environment with full privilege enforcement, and every call resolves a caller identity.

```sql
CREATE OR REPLACE FUNCTION my_catalog.fn.get_quota(rep_email STRING)
RETURNS DOUBLE
LANGUAGE SQL
COMMENT 'Returns quota for a sales rep by email. Only accessible to managers and finance.'
AS (
  SELECT CASE
    WHEN is_member('sales_managers') OR is_member('finance_team')
         THEN (SELECT quota FROM my_catalog.sales.quotas WHERE email = rep_email)
    ELSE NULL
  END
);

GRANT EXECUTE ON FUNCTION my_catalog.fn.get_quota TO `sales_managers`;
GRANT EXECUTE ON FUNCTION my_catalog.fn.get_quota TO `finance_team`;
```

**Caller-scoped result pattern** — always filter to the caller rather than trusting a passed-in identity parameter:

```sql
CREATE OR REPLACE FUNCTION my_catalog.fn.my_open_deals()
RETURNS TABLE (opp_id STRING, name STRING, status STRING)
LANGUAGE SQL
AS (
  SELECT opp_id, name, status
  FROM my_catalog.sales.opportunities
  WHERE owner_email = current_user()
    AND status != 'CLOSED'
);
```

Key properties: parameters require `COMMENT` annotations so the LLM has a usable tool-parameter description; `EXECUTE` controls callability; and UC Functions are auto-exposed as tools through the Managed MCP server at `{workspace}/api/2.0/mcp/functions/{catalog}/{schema}`, where users only see functions they already have `EXECUTE` on.

### Retriever Tool Governance (Vector Search)

Vector Search indexes inherit row-level security from their source Delta table, so the grant model is the same one you already use for tables:

```sql
GRANT USE CATALOG ON CATALOG my_catalog TO `<agent-sp-uuid>`;
GRANT USE SCHEMA  ON SCHEMA  my_catalog.rag TO `<agent-sp-uuid>`;
GRANT SELECT      ON TABLE   my_catalog.rag.documents TO `<agent-sp-uuid>`;
```

Vector Search is also available as a Managed MCP server (`{workspace}/api/2.0/mcp/vector-search/{endpoint}/{index}`), exposing `similarity_search` and `get_document` tools under the same grant model.

Use `mlflow.models.set_retriever_schema()` before logging a retriever-backed agent to map custom retriever output columns (`primary_key`, `text_column`, `doc_uri`) to the fields MLflow's Agent Evaluation judges expect — this enables automatic groundedness and relevance scoring without manual mapping.

### Agent-as-Tool Composition and Agent Bricks Supervisors

Multi-agent systems compose in two governance-relevant ways: a parent agent calling a deployed sub-agent as a tool, and a no-code supervisor built with Agent Bricks routing to sub-agents (Genie Spaces, UC Functions, Vector Search, and other agents).

Agent Bricks currently offers building blocks including Knowledge Assistants for document Q&A, Genie Spaces for structured data Q&A, and Multi-Agent Supervisors for orchestrating across sub-agents (see the [Agent Bricks documentation](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/)).

```
User Query
    ↓
Supervisor Agent
    ├── Genie Space sub-agent       → NL-to-SQL, UC row filters fire
    ├── UC Function sub-agent       → EXECUTE-gated business logic
    └── Vector Search sub-agent     → semantic retrieval
         ↓
Each sub-agent enforces the calling user's permissions
```

**The governance property that matters**: the supervisor forwards the user's OAuth token to each sub-agent. Row filters, column masks, and function-level access controls all fire as the calling user, with no additional auth code in the supervisor. For custom (non-Agent-Bricks) agent-as-tool composition, the same principle applies — the parent agent's token propagates to the sub-agent endpoint, and the sub-agent's own serving-endpoint grants (`CAN_QUERY`) are independent of the parent's.

**Permission requirements per sub-agent type**:

| Sub-agent type | Required grant |
|---|---|
| Genie Space | `CAN_USE` on the space |
| UC Function | `EXECUTE` privilege |
| Vector Search index | `SELECT` on the underlying Delta table |
| Sub-agent (another serving endpoint) | `CAN_QUERY` on that endpoint |

**Routing description quality is a governance control, not just a UX detail**: the supervisor LLM chooses a sub-agent based on its description. Write descriptions that state both what data the sub-agent answers questions about *and* what access restrictions apply — for example, "Returns quota for a sales rep by email; only accessible to managers and finance; requires rep_email parameter." A vague description increases the chance of routing a sensitive question to the wrong sub-agent, or of the agent attempting a call it will predictably be denied.

**Response parsing note**: some supervisor responses place intermediate reasoning in earlier entries of the `choices` array — read the last entry (`choices[-1]`) for the final answer rather than assuming `choices[0]`.

---

## External System Integration Patterns

### CRM Systems (Salesforce, HubSpot)

The agent calls `{workspace}/api/2.0/mcp/external/{connection_name}`. Databricks checks `USE CONNECTION` and injects the credential server-side. Agent code holds no raw credential.

**Required controls for write operations**:
1. UC Function as the interface — not a direct MCP tool call to the CRM API
2. `current_user()` attribution in every CRM update
3. Read-before-write confirmation (preview before commit)
4. Rate limiting per user (max N CRM updates per hour via agent)
5. CRM audit trail correlation (vendor-side event monitoring joined with Databricks audit)

### HRM Systems (Workday, BambooHR, ADP)

HRM data has the highest governance bar. Mandatory controls — no exceptions:

- Agent SP gets `EXECUTE` on specific HR UC Functions; never `SELECT` on HR tables
- Dedicated catalog for all HR data; column masks on all PII fields by default
- No LLM has `SELECT` on raw HR tables — LLMs execute UC Functions that return computed values only
- All calls to the HR catalog appear in `system.access.audit` with elevated monitoring and alerting configured

### General Pattern

The agent calls the external system through a UC External HTTP Connection. Databricks checks `USE CONNECTION` privilege and injects the credential server-side. The agent code never holds a raw credential. The same proxy pattern also works for calling third-party SDKs directly (for example, a chat SDK or an OpenAI-compatible client) pointed at the UC connection's proxy URL instead of wrapping every call in a UC Function.

```
Agent --> {workspace}/api/2.0/mcp/external/{connection_name}
           |
           Databricks checks USE CONNECTION privilege
           |
           Injects credential server-side
           |
           External system
```

---

## Layer 6 in Practice: Correlating Traces with Audit Logs

The audit layer is really two planes that must be joined to get a complete picture: MLflow traces (what the agent decided, what tools it called) and `system.access.audit` (what UC objects were actually touched). Neither alone shows the full chain of custody — join them on the agent's service-principal identity and a shared time window:

```sql
WITH agent_sessions AS (
  SELECT trace_id, start_time, end_time,
    attributes:tags.user_email AS initiating_user,
    attributes:tags.agent_sp_id AS agent_sp_id
  FROM mlflow.traces
  WHERE start_time >= current_timestamp() - INTERVAL 24 HOURS
),
data_access AS (
  SELECT event_time,
    JSON_VALUE(identity_token, '$.email') AS accessor_identity,
    JSON_VALUE(request_params, '$.resource') AS resource_accessed,
    action_name
  FROM system.access.audit
  WHERE event_time >= current_timestamp() - INTERVAL 24 HOURS
)
SELECT s.trace_id, s.initiating_user, d.event_time,
  d.accessor_identity, d.resource_accessed, d.action_name
FROM agent_sessions s
JOIN data_access d
  ON d.accessor_identity IN (s.initiating_user, s.agent_sp_id)
  AND d.event_time BETWEEN s.start_time AND s.end_time
ORDER BY s.trace_id, d.event_time;
```

This answers "who asked, what did the agent decide, and what data did it touch" in one query — the application plane (MLflow) supplies the decision trail, the data plane (`system.access.audit`) supplies the access trail, and the SP identity plus time window ties them together. See [`observability/agent-tracing.md`](../observability/agent-tracing.md) for the full tracing setup this depends on.

**A demo walkthrough that proves all six layers**, useful for showing a stakeholder end-to-end governance rather than describing it abstractly:

| Step | What to show | Layer |
|---|---|---|
| 1 | `SHOW GRANTS` on the agent SP — only specific objects appear | L1 + L2 |
| 2 | Query as an OBO user — row filters restrict results per identity | L3 |
| 3 | `GRANT`/`REVOKE USE CONNECTION` on an external tool — access toggles live | L4 |
| 4 | Agent writes through a UC Function, not a raw `INSERT` — invariants enforced, attribution logged | L2 + L3 |
| 5 | Run the chain-of-custody query above | L6 |
| 6 | Revoke `CAN_QUERY` on the serving endpoint — the agent stops immediately | L5 |

---

## Confused Deputy Defense

If an untrusted identity cannot `USE` the connection, no amount of prompt injection or tool manipulation can exfiltrate data through that connection. The SQL engine enforces this — not the agent code.

This is the critical distinction between platform-enforced controls and convention-based controls. Row filters, column masks, and `USE CONNECTION` checks fire at the engine level regardless of how the query arrived — whether from a well-behaved agent, a compromised agent, or a direct SQL query. The agent code does not need to implement these controls, and cannot bypass them.

---

## Related

- `data-governance/row-filters.md` — Row filter patterns, OBO vs M2M, current_user() vs is_member()
- `data-governance/column-masks.md` — Column mask patterns and chaining
- `identity/obo-passthrough.md` — OBO implementation patterns
- `identity/service-principals.md` — SP setup and grant minimization
- `tool-governance/uc-connections.md` — UC Connections for external system access
- `tool-governance/mcp-governance.md` — MCP server governance (managed, external, custom)
- `observability/` — Audit and tracing patterns
