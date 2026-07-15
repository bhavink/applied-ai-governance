<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: mcp/overview.md, mcp/managed-mcp.md, mcp/custom-mcp.md, mcp/external-mcp.md, mcp/external-connection-tools.md
  Public docs grounding: https://docs.databricks.com/aws/en/generative-ai/mcp/
  This file is auto-prepared and human-reviewed before publish.
-->

# MCP Governance — Server Types, Tool Selection, and Auth Patterns

> **TL;DR**: Databricks supports three MCP server types — Managed, Custom, and External — all reachable through the same `DatabricksMCPClient` API and `{workspace}/api/2.0/mcp/...` URL namespace, with Unity Catalog enforcing permissions on every call. For external tools, MCP Services are Unity Catalog securables — the recommended pattern for governing access to third-party MCP servers. Seven built-in `system.ai.*` services (Slack, GitHub, Atlassian, Google Drive, Google Calendar, Gmail, SharePoint) are ready to grant with zero setup. The UC HTTP connection proxy pattern remains a valid option for existing integrations and services not yet available as MCP Services.

See also: [MCP overview](https://docs.databricks.com/aws/en/generative-ai/mcp/).

---

## Three MCP Server Types

| Type | What it is | Auth model | Use when |
|---|---|---|---|
| **Managed** | Databricks-hosted MCP wrapping built-in data services | OBO or M2M via `DatabricksMCPClient` | Agent needs Genie, Vector Search, UC Functions, or DBSQL |
| **Custom** | Your own MCP server hosted as a Databricks App | OAuth only (OBO or M2M); PATs are not applicable | Custom business logic to expose as tools |
| **External** | Third-party MCP servers as UC MCP Services, or proxied through a UC HTTP connection (legacy) | Managed OAuth (UC MCP Service) or Custom HTTP / DCR (connection proxy) | External services; UC governs access |

All Databricks MCP servers communicate over Streamable HTTP transport, so client tooling should target that transport when connecting.

### URL patterns

```
# Managed MCP — Databricks-hosted servers
Genie:          {host}/api/2.0/mcp/genie/{genie_space_id}
Vector Search:  {host}/api/2.0/mcp/vector-search/{catalog}/{schema}/{index_name}
UC Functions:   {host}/api/2.0/mcp/functions/{catalog}/{schema}/{function_name}
              OR {host}/api/2.0/mcp/functions/{catalog}/{schema}   ← entire schema
DBSQL:          {host}/api/2.0/mcp/sql

# External MCP — UC MCP Service (recommended)
MCP Service:    {host}/ai-gateway/mcp-services/{catalog}.{schema}.{service_name}

# External MCP — UC HTTP connection proxy (legacy)
Connection proxy: {host}/api/2.0/mcp/external/{uc_connection_name}

# Custom MCP — your server hosted on Databricks Apps
Custom:         https://{app-url}/mcp
```

### Standard client pattern (same shape for all server types)

```python
from databricks_mcp import DatabricksMCPClient
from databricks.sdk import WorkspaceClient

workspace_client = WorkspaceClient()               # auto-discovers credentials
mcp_client = DatabricksMCPClient(
    server_url="https://<workspace>/api/2.0/mcp/...",
    workspace_client=workspace_client,
)

tools  = mcp_client.list_tools()                   # discover available tools
result = mcp_client.call_tool("tool_name", {"param": "value"})
```

```bash
pip install "mcp>=1.9" "databricks-sdk[openai]" "mlflow>=3.1.0" \
            "databricks-agents>=1.0.0" "databricks-mcp"
```

---

## Decision Tree

```
Agent needs to call a tool
  ├─ Data in Databricks? → MANAGED MCP (Genie, Vector Search, UC Functions, DBSQL)
  ├─ Custom business logic YOU own? → CUSTOM MCP (Databricks Apps)
  └─ External service?
        ├─ Slack, GitHub, Atlassian, Google, SharePoint? → system.ai.* MCP Service (GRANT EXECUTE)
        ├─ Other third-party with MCP support? → UC MCP Service (catalog.schema.svc)
        └─ Existing UC HTTP connection? → Connection proxy (legacy, still functional)
```

---

## Auth Comparison

Which credential to use depends on where the calling code runs:

| Calling context | Token type | How to obtain |
|---|---|---|
| Local dev / Claude Code / Cursor | User OAuth (PKCE) | `mcp-remote` with `--static-oauth-client-info` |
| Databricks App (OBO) | User's forwarded token | `ModelServingUserCredentials()` from `databricks.sdk` (Model Serving contexts) |
| Databricks App (M2M) | App service principal credentials | `WorkspaceClient()` with no args — SDK auto-discovers `DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET` |
| External app via federation | Databricks OAuth token | Exchange the external identity token via RFC 8693 token exchange |
| PAT (dev/testing) | Personal Access Token | `--header "Authorization: Bearer <PAT>"` in `mcp-remote` |

Managed and External MCP servers accept PATs for local development and testing. Custom MCP servers hosted on Databricks Apps use OAuth exclusively (OBO or M2M) since Apps proxy authentication runs through OAuth end to end.

---

## MCP Services — UC Securables (Recommended Pattern for External Tools)

MCP Services are first-class Unity Catalog objects: `catalog.schema.mcp_service`. Governing an external MCP integration is the same workflow as governing a table or function — grant, revoke, audit.

### The governance model

```sql
-- Grant a principal the ability to call an MCP service
GRANT EXECUTE ON MCP SERVICE catalog.schema.svc TO principal;

-- Revoke is instant, no redeployment needed
REVOKE EXECUTE ON MCP SERVICE catalog.schema.svc FROM principal;
```

Audit actions — `createMcpService`, `updateMcpService`, `deleteMcpService`, `mcpCall` — are captured in `system.access.audit` alongside standard UC events.

**Management API**: `/api/2.1/unity-catalog/mcp-services`. Create and update MCP Services through the Catalog Explorer UI or this REST API; SQL DDL for MCP Services is on the roadmap.

### Permissions checklist

| Action | Privilege needed |
|---|---|
| Create the underlying UC HTTP connection | `CREATE CONNECTION` on the metastore or schema |
| Create an MCP Service | `USE CATALOG` + `USE SCHEMA` + `CREATE SERVICE` on the parent schema, plus `USE CONNECTION` on the connection |
| Invoke an MCP Service | `EXECUTE` on the MCP Service (no connection privilege required) |

Grant `EXECUTE` to end users and groups; keep `USE CONNECTION` scoped to service authors and admins. Granting `USE CONNECTION` broadly to end users lets them call the external server directly, bypassing tool selection, service policies, and auditing.

### Built-in system services (zero setup)

Seven services in the `system.ai.*` namespace are managed by Databricks — no connection configuration, no credential management. Grant `EXECUTE` to the identities that need access:

| Service | UC name | Connects to |
|---|---|---|
| Slack | `system.ai.slack` | Slack |
| GitHub | `system.ai.github` | GitHub |
| Atlassian | `system.ai.atlassian` | Jira and Confluence |
| Google Drive | `system.ai.google_drive` | Google Drive |
| Google Calendar | `system.ai.google_calendar` | Google Calendar |
| Gmail | `system.ai.gmail` | Gmail |
| SharePoint | `system.ai.sharepoint` | Microsoft SharePoint |

```sql
GRANT EXECUTE ON MCP SERVICE system.ai.github TO `dev-team`;
```

Databricks manages the OAuth registration for these providers — no stored credentials, no `http_request()` wiring required.

### Tool filtering and service policies

Tool selection controls which tools an MCP Service exposes from the underlying server:

- **Prefix match** — `get_*` matches `get_me`, `get_issue`, etc.
- **Exact match** — `search_repositories` matches only that tool
- **Auto-include future tools** — toggle to automatically expose new tools as the server adds them

Selection currently supports prefix and exact-match includes; scope broad grants to the tools you intend to expose rather than relying on excludes. Unselected tools are hidden from `tools/list` and rejected on `tools/call`.

Service policies add a second, evaluation-based layer on top of tool selection:

- **`ON CALL`** — evaluate before the tool executes (allow, deny, or require human approval)
- **`ON RESULT`** — evaluate after the tool returns

This gives allow/deny/approval control at the individual tool-call level, independent of which tools are exposed. See [AI Gateway governance](https://docs.databricks.com/aws/en/ai-gateway/).

### Rate limits and monitoring

Configure per-service rate limits via Unity AI Gateway to control cost and protect the downstream external server.

| Data | Where to look |
|---|---|
| Usage (call volume, errors, latency) | `system.ai_gateway.usage`, filtered to `service_type = 'MCP_SERVICE'` |
| Control-plane audit | `system.access.audit` — actions `createMcpService`, `updateMcpService`, `deleteMcpService`, `mcpCall` |
| Trace logs | Enabled at the account level, shared across MCP Services |
| Dashboard | Built-in Unity AI Gateway usage dashboard |

For an end-to-end walkthrough, see [Govern a coding agent's GitHub MCP access](https://docs.databricks.com/aws/en/ai-gateway/govern-coding-agent-tutorial).

### Registering a custom external MCP server

1. Create a UC HTTP connection at the **schema** level (Catalog Explorer, Databricks Marketplace install, or the CLI/SDK).
2. Choose an auth method for the connection: Bearer Token, OAuth M2M, OAuth U2M Shared, or OAuth U2M Per User (per-user auth requires a one-time login per user before first invocation).
3. Create the MCP Service against that connection, with the tool selection you want:

```bash
databricks api post \
  "/api/2.1/unity-catalog/mcp-services?parent=schemas/main.default&mcp_service_id=my_github_mcp" \
  --json '{
    "comment": "GitHub MCP via managed auth",
    "config": {
      "connection": {"name": "connections/main.default.github_conn"},
      "include_tool_selectors": ["get_*", "list_*", "search_repositories"]
    }
  }'

databricks api patch \
  "/api/2.1/unity-catalog/permissions/mcp_service/main.default.my_github_mcp" \
  --json '{"changes": [{"principal": "dev-team", "add": ["EXECUTE"]}]}'
```

MCP Service names (`catalog.schema.service`) are immutable once created — choose them carefully. MCP Services are scoped to external and custom MCP servers; Genie spaces, Databricks Apps, and other UC entity sources are addressed through Managed MCP instead.

---

## Tool Selection Priority (MCP-First)

| Priority | Tool Type | Auth model | Governance | Best for |
|---|---|---|---|---|
| 1 | **Managed MCP server** | OBO or SP (auto) | UC privileges | Default choice — dynamic tool discovery |
| 2 | **UC MCP Service** (`system.ai.*` or `catalog.schema.svc`) | Managed OAuth (Databricks-managed) | `EXECUTE` on MCP Service | GitHub, Slack, Atlassian, Google, SharePoint — zero credential management |
| 3 | **External MCP server via UC connection** (legacy) | `USE CONNECTION` + stored creds | `USE CONNECTION` privilege | Existing integrations not yet migrated to MCP Services |
| 4 | **Custom MCP server** | Custom (your server's auth) | Code-level + connection | Internal APIs, custom integrations |
| 5 | **UC Function** | Caller's identity (OBO) or SP | `EXECUTE` privilege | Deterministic computations, data lookups |
| 6 | **Retriever tool (Vector Search)** | SP (M2M) or OBO | `SELECT` on VS index | Document Q&A, semantic search |
| 7 | **Agent-as-tool** | Inherits parent's auth | Same as parent | Multi-agent orchestration |
| 8 | **Custom Python function** | Defined in code | Code-level | Last resort — ungoverned |

**Why MCP-first?** MCP servers provide standardized tool discovery, schema validation, and auth delegation. Agents dynamically discover available tools at runtime instead of hardcoding tool definitions.

---

## UC Permissions by Server Type

| Server type | What UC enforces |
|---|---|
| Managed — Genie | `CAN_USE` on the Genie space; row filters + column masks enforced per `current_user()` on underlying tables |
| Managed — Vector Search | `CAN_SELECT` on the VS index (the only permission granularity available) |
| Managed — UC Functions | `EXECUTE` on each function, plus `USE SCHEMA` and `USE CATALOG` on the containing schema/catalog |
| Managed — DBSQL | Full UC table/schema/catalog privileges; supports read and write, since the agent can generate arbitrary SQL |
| **UC MCP Service** | `EXECUTE` on `catalog.schema.mcp_service`; tool-level allow/deny/approval via service policies |
| External (connection proxy, legacy) | `USE CONNECTION` on the UC HTTP connection |
| Custom | Whatever your tool code enforces (OBO → user identity propagated; M2M → SP identity) |

**Building with Genie MCP**: each MCP call to a Genie space is stateless — conversation history isn't passed between calls. For multi-turn conversational Genie inside an agent, use the Genie-in-a-multi-agent-system pattern so history is preserved at the orchestration layer.

**Long-running queries**: Genie and DBSQL queries that exceed the MCP call timeout return a polling token — implement polling on the response rather than waiting on a single synchronous call.

**Row filters with `is_member()`**: when a Genie space runs a query under its own execution identity, `is_member()` in a row filter won't evaluate against the OBO caller's groups. Scope the filter with `current_user()` plus an allowlist table instead. See [Governance recipes](ai-gateway-governance-recipe.md).

### UC MCP Services — Recommended path for external integrations

MCP Services surface as `catalog.schema.mcp_service` in the UC object hierarchy. The governance workflow is identical to functions and tables:

1. Create or reference an MCP Service (built-in `system.ai.*`, or custom via `/api/2.1/unity-catalog/mcp-services`).
2. `GRANT EXECUTE ON MCP SERVICE catalog.schema.svc TO principal`.
3. Optionally configure service policies to allow/deny specific tools or add approval gates.
4. Agent discovers and calls tools — Databricks handles OAuth token exchange, no credentials in app code.
5. All calls audited as `mcpCall` in `system.access.audit`.

For the seven built-in services, step 1 is skipped — the service already exists in `system.ai.*`.

### External Connection Proxy — legacy path

The connection proxy (`/api/2.0/mcp/external/{connection_name}` + `USE CONNECTION` grant) remains a valid option for existing integrations, or for regions/services where MCP Services aren't yet available. UC checks `USE CONNECTION` before every proxy request; the agent code never touches raw credentials, since Databricks injects them server-side. `REVOKE USE CONNECTION` is instant, requires no redeployment, and is audited in `system.access.audit`.

**Installation methods**:

| Method | When to use |
|---|---|
| **Managed OAuth** | Recommended for supported providers — Glean, GitHub, Atlassian, Google Drive, SharePoint. Databricks manages OAuth end to end. |
| **Databricks Marketplace** | Install a pre-configured connection for a listed MCP server. |
| **Custom HTTP Connection** | Any server exposing Streamable HTTP; configure host, path, and bearer token directly. |
| **Dynamic Client Registration (RFC 7591)** | For MCP servers implementing DCR. Treat as experimental — validate before relying on it in production, and note that DCR OAuth flows aren't part of every external MCP client's auth path (check your client's supported flows). |

For Managed OAuth and workspaces with restrictive networking, allowlist the cloud-specific OAuth redirect URI and, if the workspace has IP access lists enabled, add the client's outbound IPs (Workspace Settings → **Security** → **IP Access List**).

**Connection ownership**: the connection creator retains implicit `USE CONNECTION` that can't be revoked directly. Transfer ownership with `ALTER CONNECTION ... SET OWNER TO ...` if the creator should no longer hold access.

**Auditing external connection access**:

```sql
SELECT event_time, user_identity.email, action_name, request_params
FROM system.access.audit
WHERE action_name IN ('useConnection', 'getConnection')
  AND event_time > current_timestamp() - INTERVAL 1 DAY
ORDER BY event_time DESC;
```

---

## Direct HTTP Access Through a UC Connection (No MCP Layer)

When the external service doesn't expose an MCP server — or the integration is a single fixed API call — route it through the same UC HTTP connection governance without the MCP layer, using the SDK's `http_request()`:

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.serving import ExternalFunctionRequestHttpMethod

w = WorkspaceClient()
response = w.serving_endpoints.http_request(
    conn="slack_connection",
    method=ExternalFunctionRequestHttpMethod.POST,
    path="/api/chat.postMessage",
    json={"channel": "C0EXAMPLE", "text": "Hello from agent"},
)
```

The same call can be wrapped as a UC function for SQL-based tool definitions; auth and `USE CONNECTION` governance are identical either way. Per-user (U2M Per User) connections require the Python SDK path — SQL `http_request()` is scoped to non-per-user auth types.

| Use MCP when | Use `http_request()` when |
|---|---|
| The external service has an MCP server | No MCP server is available |
| You want automatic tool discovery | You know the exact API calls needed |
| The agent needs to dynamically select among tools | The integration is one or two fixed API calls |

### Auth method selection

| Auth method | Best for | Per-user identity? | Setup complexity |
|---|---|---|---|
| Bearer Token | Simple API keys (PAT-style) | No | Low |
| OAuth M2M | OAuth services, shared service account | No | Medium |
| OAuth U2M Shared | OAuth, single org-level identity | No | Medium |
| OAuth U2M Per User | User-specific resources (personal repos, calendars) | Yes | Higher — each user completes a one-time consent flow |

---

## Custom MCP Server — Governance Considerations

Custom MCP servers introduce a **two-proxy pattern**: when one Databricks App calls another, the downstream app's proxy independently injects its own forwarded-token header, so the identity arriving at your server's code is the calling app's service principal, not the originating user — unless you read the identity a different way.

**Key governance points:**

- `X-Forwarded-Email` — set by the Databricks Apps proxy from the authenticated caller, and can't be forged by the calling app — is the reliable OBO identity source inside a custom MCP server. Pair it with M2M SQL scoped by an explicit `WHERE` clause on the caller's identity.
- `ModelServingUserCredentials()` is built for Model Serving request context; inside a Databricks Apps MCP server it resolves to the app's M2M service principal identity rather than the calling user, so prefer `X-Forwarded-Email` for OBO in that context.
- Each app deployment has its own service principal — grants don't carry over between deployments, so re-grant UC access after redeploying to a new app.
- Custom MCP servers authenticate via OAuth (OBO or M2M) over Streamable HTTP transport.

For the two-proxy architecture diagram, ASGI middleware patterns, and full code examples, see [Proxy Architecture](../identity/proxy-architecture.md).

---

## Related

- [`uc-connections.md`](uc-connections.md) — UC HTTP connections in depth: auth methods, `http_request()`, query federation
- [`ai-gateway-patterns.md`](ai-gateway-patterns.md) — AI Gateway and model serving governance; service policies vs. guardrails
- [`ai-gateway-governance-recipe.md`](ai-gateway-governance-recipe.md) — row filter and column mask recipes
- [`../identity/`](../identity/) — OBO passthrough, M2M service principals, auth patterns
- [MCP overview](https://docs.databricks.com/aws/en/generative-ai/mcp/) · [AI Gateway](https://docs.databricks.com/aws/en/ai-gateway/) · [Govern a coding agent's GitHub MCP access (tutorial)](https://docs.databricks.com/aws/en/ai-gateway/govern-coding-agent-tutorial)
