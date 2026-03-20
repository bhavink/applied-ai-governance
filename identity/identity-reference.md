# Identity and Authentication Reference

> **Purpose**: Canonical reference for authentication patterns, token flows, identity models, and OAuth scopes across all Databricks AI products.
>
> **Audience**: Field Engineers, Solution Architects, and Security Reviewers building or evaluating AI applications on Databricks.
>
> **Last updated**: 2026-03-12

---

## 1. Three Authentication Patterns

Every Databricks AI application uses one or more of these patterns. They are universal across Agent Bricks, Databricks Apps, Genie, and custom MCP servers.

### Pattern 1: Automatic Passthrough (M2M)

Short-lived SP token (OAuth client credentials). SP has least-privilege access scoped to declared resources. Identity in audit: SP UUID.

- **Use cases**: Batch jobs, automation, background tasks, shared-resource queries
- **Docs**: [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m.html), [Automatic Passthrough](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#automatic-authentication-passthrough)

### Pattern 2: On-Behalf-Of User (OBO)

Agent or app runs as the end user. UC enforces row filters, column masks, and ABAC per user. Identity in audit: human email.

- **Key requirement**: Initialize user-authenticated clients inside `predict()` at request time; declare required scopes
- **Docs**: [OBO Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#on-behalf-of-user-authentication)

### Pattern 3: Manual Credentials

External API keys or SP OAuth credentials stored in Databricks Secrets. UC not involved.

- **Use cases**: External LLM APIs, external MCP servers, third-party SaaS
- **Docs**: [Manual Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#manual-authentication)

### When to Use Each

| Question | Answer |
|---|---|
| User should only see their data? | OBO (Pattern 2) |
| Everyone sees the same data? | M2M (Pattern 1) |
| Need user identity in platform audit? | OBO where possible; app-level audit for M2M paths |
| External API or third-party service? | Manual Credentials (Pattern 3) |
| Background/batch processing? | M2M (Pattern 1) |

---

## 2. Token Flows and the Two-Proxy Problem

### Databricks Apps Token Architecture

The platform proxy injects identity headers into every request. When `user_authorization_enabled: true`, these headers cannot be forged by calling apps.

| Header | Content | Trust level |
|---|---|---|
| `X-Forwarded-Email` | `alice@example.com` | High |
| `X-Forwarded-User` | `{user_id}@{workspace_id}` | High |
| `X-Forwarded-Preferred-Username` | Display name | High |
| `X-Forwarded-Access-Token` | Minimal OIDC JWT (iam.* scopes only) | Medium (identity only) |

### The Two-Proxy Problem

When App A (Streamlit) calls App B (MCP server), each has its own proxy. Proxy 2 **strips** the incoming Authorization header and injects its own SP token. The MCP server never sees the user's OBO token.

**Solution**: Use `X-Forwarded-Email` (proxy-verified, cannot be forged) for user identity. Use `WorkspaceClient()` (M2M, no args) for SQL queries with explicit `WHERE user_email = '{caller}'` filtering.

### The Three-Proxy Path (UC External MCP)

When the MCP server is registered as a UC HTTP Connection, a third proxy validates the `unity-catalog` scope and checks `USE CONNECTION` privilege. Revoking `USE CONNECTION` immediately blocks access.

### What NOT to Use in MCP Servers

- `ModelServingUserCredentials()` silently falls back to M2M in Apps context
- `WorkspaceClient(host=host, token=user_token)` raises conflict error if `DATABRICKS_CLIENT_ID/SECRET` env vars are also set
- `X-Forwarded-Access-Token` for SQL (token lacks `sql` scope unless configured via UI)

---

## 3. Identity Models per Service

| Service | Auth Pattern | Identity in `system.access.audit` | Human Visible? |
|---|---|---|---|
| Genie Space | OBO | Human email | Yes |
| Agent Bricks | Automatic passthrough | SP UUID | No |
| Agent Bricks | OBO | Human email | Yes |
| SQL Warehouse (M2M) | M2M | SP UUID | No |
| SQL Warehouse (OBO + UI scopes) | OBO | Human email | Yes |
| Custom MCP (direct) | Two-proxy M2M | SP UUID (App B SP) | No |
| Custom MCP (UC proxy) | Three-proxy | Calling identity at UC layer | Partially |
| Vector Search | Automatic passthrough | SP UUID | No |
| External APIs | Manual credentials | External service logs | N/A |

---

## 4. OAuth Scope Reference

> **Verified on Azure Databricks, March 2026.** Add ALL scopes upfront. Missing scopes cause cryptic errors discovered per-feature, not per-project. Extra scopes are harmless.

### Scope Map

| Scope | Required for | Notes |
|---|---|---|
| `dashboards.genie` | Genie Conversation API (all clouds) | Must be in `user_authorized_scopes` |
| `genie` | Genie on **Azure** | Azure-specific; add via CLI since UI does not show it |
| `model-serving` | Agent Bricks / Model Serving OBO | |
| `sql` | Statement Execution API | CLI config does NOT embed in JWT; use UI "User authorization" |
| `unity-catalog` | External MCP proxy | Missing = 403 |
| `all-apis` | General REST APIs | Catch-all |

### Two Configuration Paths

| Mechanism | Result |
|---|---|
| **CLI** `custom-app-integration update` | Sets scopes in config but does NOT populate `effective_user_api_scopes`. Proxy still issues minimal OIDC token. |
| **UI** User Authorization | Sets both config AND `effective_user_api_scopes`. Produces real OBO JWT with service scopes. |

**Always use the UI** for scopes you need in the token's `scope` claim.

### UI Scope Names

| UI scope name | What it enables |
|---|---|
| `sql` | OBO SQL via Statement Execution API |
| `dashboards.genie` | Genie space access |
| `serving.serving-endpoints` | Model Serving / Agent Bricks OBO |
| `catalog.connections` | UC HTTP Connection access |

### OAuth Integration Reset

Adding a scope to `user_authorized_scopes` does NOT affect existing refresh tokens. The access token inherits scopes from the original authorization code grant, not the current config. **The only fix**: Delete and recreate the app, then immediately patch the new integration with the full scope set.

---

## 5. Identity Design Considerations

### Multi-Service Identity Fragmentation

A single user interaction may show human email for Genie queries (OBO) but SP UUID for M2M SQL queries in `system.access.audit`. The human who triggered an M2M query is only visible in the application plane.

### Best Practices

| Consideration | Best practice |
|---|---|
| Preserving human identity in M2M audit paths | Use OBO SQL (UI "User authorization" with `sql` scope) where possible; add app-level audit for M2M |
| Correlating MLflow traces with platform audit | Generate a `trace_id` at agent entry point, pass through tools, join on shared `trace_id` or timestamp window |
| Minimizing token scope | Declare minimum required scopes explicitly rather than `all-apis` |
| `is_member()` under OBO | Evaluates SQL execution identity, not calling user. Use `current_user()` + allowlist table instead |

### Two-Layer Audit Architecture

Application plane (you build it): MLflow traces to Delta table with human email, trace_id, tool calls. Data plane (platform-provided): `system.access.audit` with executing identity. Correlation: JOIN on shared trace_id or timestamp window.

---

## 6. Quick Decision Guide

### Choosing an Auth Pattern

```
Is the user accessing their own data?
  +-- YES --> Use OBO (Pattern 2)
  +-- NO  --> Is this a shared/system resource?
               +-- YES --> Use M2M (Pattern 1)
               +-- NO  --> Is this an external service?
                            +-- YES --> Manual Credentials (Pattern 3)
                            +-- NO  --> Re-evaluate your architecture
```

### Choosing SQL Authentication

```
Do you need per-user row filter enforcement at the SQL layer?
  +-- YES --> OBO SQL (configure sql scope via Account Console UI)
  +-- NO  --> M2M SQL (WorkspaceClient() with no args, add app-level logging)
```

---

## 7. Complete Service Identity Map

Three identity models:

| Model | `current_user()` returns | UC audit shows |
|---|---|---|
| **True OBO** | User email | User email |
| **Proxy identity + M2M** | SP UUID | SP UUID |
| **Pure M2M** | SP UUID | SP UUID |

### Per-Service Breakdown

| # | Service | Identity model | `current_user()` | UC audit identity |
|---|---|---|---|---|
| 1 | Genie (Conversation API) | True OBO | User email | User |
| 2 | AI/BI Dashboard (run-as-viewer) | True OBO | Viewer email | Viewer |
| 3 | AI/BI Dashboard (run-as-owner) | Delegated | Owner email | Owner |
| 4 | Agent Bricks / Model Serving | True OBO | User email | User |
| 5 | SQL Warehouse (user token) | True OBO | User email | User |
| 6 | SQL Warehouse (SP token) | Pure M2M | SP UUID | SP UUID |
| 7 | Custom MCP (Databricks Apps) | Proxy + M2M or True OBO | SP UUID (M2M) / User email (OBO SQL) | Depends on config |
| 8 | UC Functions (via M2M SQL) | Pure M2M | SP UUID | SP UUID |
| 9 | UC Functions (via Genie OBO) | True OBO | User email | User |
| 10 | Vector Search | Pure M2M | N/A | SP UUID |
| 11 | External MCP (shared bearer) | M2M at proxy | N/A | Caller at proxy |
| 12 | External MCP (per-user OAuth) | OBO at proxy | N/A | User at proxy |

### Audit Coverage by Identity Model

| Identity model | UC audit captures human? | App-plane audit recommended? |
|---|---|---|
| True OBO (#1, 2, 4, 5, 9) | Yes | Optional (enrichment) |
| Proxy identity + M2M (#7) | No (SP UUID). Use UI User Auth + `sql` scope for OBO SQL. | Yes for M2M path |
| Pure M2M (#6, 8, 10) | No | Yes if per-user attribution matters |
| Delegated (#3) | Yes (but shows owner, not end user) | Depends on use case |

---

## 8. Audit Decorator Pattern

The `@audited` decorator wraps any MCP tool with audit logging. Zero changes to tool logic required.

### Design Goals

1. Every invocation records who (human) asked for what (tool + args) via which agent (SP)
2. Records are immutable (Delta table, append-only, change data feed enabled)
3. Joinable with `system.access.audit` via SP UUID + time window
4. Joinable with `mlflow.traces` via trace_id
5. Zero code changes to tool logic

### Pattern Shape

The audit table stores: caller identity (from proxy headers), SP identity (`DATABRICKS_CLIENT_ID`), tool name, sanitized args, result status, trace_id, event timestamp, and duration. The decorator extracts caller email from request headers, wraps the tool function, and writes a record on completion or error.

```python
@mcp.tool()
@audited()
def my_tool(arg1: str) -> dict:
    ...  # existing logic unchanged
```

The `@audited(service_type="uc_function")` variant tags the service type for correlation queries.

---

## 9. Chain-of-Custody

The chain-of-custody query joins the app-plane audit table with `system.access.audit` to produce: human > tool > SQL > data. Join on `app_sp_id = user_identity.email` within a timestamp window (2s before to 30s after the tool invocation). UC only knows the SP ran queries; your audit table proves which human triggered them.

---

## 10. Confused Deputy Prevention

### The Principle: One SP per Capability Boundary

Every deployed agent is a Service Principal. An agent that does read-only analysis and an agent that submits approvals must have different SPs.

| Scenario | Single shared SP | Isolated SPs |
|---|---|---|
| Frontend compromised | Attacker has MODIFY on approval table | SP-A has no MODIFY; attack surface = read-only |
| MCP tool injection | SP accesses all tables across all apps | SP-B has grants on specific tables only |
| Credential rotation | Must rotate for all apps simultaneously | Rotate per-app independently |
| Audit investigation | All queries show same SP UUID | Different SP UUIDs give immediate attribution |

**Anti-patterns**: Sharing `DATABRICKS_CLIENT_ID/SECRET` across apps. Granting `ALL PRIVILEGES` on a catalog to an SP. Using same SP for read and write tools. Adding the MCP SP to admin groups.

---

## 11. System Tables Inventory

### Access and Audit

| Table | What it records | Useful for |
|---|---|---|
| `system.access.audit` | All UC operations, SQL, API calls, app lifecycle | Primary audit trail |
| `system.access.table_lineage` | Table-level data flow | Data flow through pipelines/agents |
| `system.access.column_lineage` | Column-level data flow | PII propagation tracking |

### Governance Metadata

| Table | Useful for |
|---|---|
| `system.information_schema.column_tags` | ABAC policies, data classification audit |
| `system.information_schema.column_masks` | Verify masks on sensitive columns |
| `system.information_schema.metastore_privileges` | Privilege escalation detection |

### Compute, Billing, MLflow

| Table | Useful for |
|---|---|
| `system.billing.usage` | Cost attribution per user/SP/workspace |
| `system.compute.clusters` | Cluster ownership, resource tracking |
| `mlflow.traces` | App-plane audit: what the agent decided, what tools it called |

---

## Related Documents

- [Authorization Flows](authorization-flows.md) - UC four-layer access control
- [OBO vs M2M Decision Matrix](obo-vs-m2m-decision-matrix.md) - Decision framework with audit implications
- [Observability and Audit](observability-and-audit.md) - Two-layer audit model, correlation
- [UC Policy Design Principles](../UC-POLICY-DESIGN-PRINCIPLES.md) - `current_user()` vs `is_member()` in all contexts
