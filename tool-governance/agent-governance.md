# Agent Governance Framework

> **TL;DR**: A governed AI system requires controls at six distinct layers. Agents must have explicit SP identities — never inherited user shells. OBO propagates the user token end-to-end; M2M runs as the SP. Audit requires joining MLflow traces (application plane) + system.access.audit (data plane).

---

## The Six Enforcement Layers

Every AI architecture decision maps to one or more of these layers. Never accept a design that relies on a single layer.

```
+-------------------------------------------------------------+
|  LAYER 6: AUDIT & OBSERVABILITY                             |
|  system.access.audit + MLflow traces + application logs     |
+-------------------------------------------------------------+
|  LAYER 5: EXECUTION BOUNDARY                                |
|  Model Serving · Databricks Apps · serverless compute       |
+-------------------------------------------------------------+
|  LAYER 4: OUTBOUND CONTROL                                  |
|  UC Connections · Serverless Network Policies (SNP)         |
+-------------------------------------------------------------+
|  LAYER 3: DATA GOVERNANCE                                   |
|  Row Filters · Column Masks · ABAC · UC Functions (write)   |
+-------------------------------------------------------------+
|  LAYER 2: PERMISSION MODEL                                  |
|  Unity Catalog privileges · least-privilege SP grants       |
+-------------------------------------------------------------+
|  LAYER 1: IDENTITY                                          |
|  Agent SP identity · User OBO · Token federation            |
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
| P8 | **OBO preserves the user chain** | When an agent acts on behalf of a user, the user's identity flows to every downstream data access. The user's permissions — not the agent's — govern what data is returned. |
| P9 | **Capability matches declared intent** | An agent deployed for "read-only deal analysis" must be technically incapable of write operations — not just conventionally restricted. |
| P10 | **Workspace isolation is zero-trust** | New workspace members receive no access by default. The default group carries no entitlements. |

---

## Agent Identity: One SP per Capability Boundary

**The problem**: When a developer runs Claude Code locally, the agent inherits the developer's shell identity. There is no audit record showing "an agent did this" vs "the developer typed this."

**The answer**: Every deployed agent is a Service Principal. One SP per capability boundary — not one SP per application. An agent that does read-only deal analysis and an agent that submits deal approvals must have different SPs.

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

## External System Integration Patterns

### CRM Systems (Salesforce, HubSpot)

The agent calls `{workspace}/api/2.0/mcp/external/{connection_name}`. Databricks checks `USE CONNECTION` and injects the credential server-side. Agent code holds no raw credential.

**Required controls for write operations**:
1. UC Function as the interface — not a direct MCP tool call to the CRM API
2. `current_user()` attribution in every CRM update
3. Read-before-write confirmation (preview before commit)
4. Rate limiting per user (max N CRM updates per hour via agent)
5. CRM audit trail correlation (Salesforce Event Monitoring + Databricks audit join)

### HRM Systems (Workday, BambooHR, ADP)

HRM data has the highest governance bar. Mandatory controls — no exceptions:

- Agent SP gets `EXECUTE` on specific HR UC Functions; never `SELECT` on HR tables
- Dedicated catalog for all HR data; column masks on all PII fields by default
- No LLM has `SELECT` on raw HR tables — LLMs execute UC Functions that return computed values only
- All calls to the HR catalog appear in `system.access.audit` with elevated monitoring and alerting configured

### General Pattern

The agent calls the external system through a UC External HTTP Connection. Databricks checks `USE CONNECTION` privilege and injects the credential server-side. The agent code never holds a raw credential.

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
- `observability/` — Audit and tracing patterns
