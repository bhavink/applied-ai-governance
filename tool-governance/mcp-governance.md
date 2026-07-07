<!--
  Synced from databricks-fieldkit on 2026-07-07
  Sources: mcp/overview.md, mcp/managed-mcp.md, mcp/custom-mcp.md, mcp/external-mcp.md, mcp/external-connection-tools.md, mcp/mcp-services.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/generative-ai/mcp/
  This file is auto-prepared and human-reviewed before publish.
-->

# MCP Governance — Server Types, Tool Selection, and Auth Patterns

> **TL;DR**: MCP Services are now Unity Catalog securables — the recommended pattern for governing external tool access. Seven built-in `system.ai.*` services (Slack, GitHub, Atlassian, Google Drive, Google Calendar, Gmail, SharePoint) are ready to grant with zero setup. The older UC connection proxy approach remains functional for existing integrations but is not the recommended path for new work.

---

## MCP Services — UC Securables (Recommended Pattern)

MCP Services are now first-class Unity Catalog objects: `catalog.schema.mcp_service`. Governing an external MCP integration is the same workflow as governing a table or function — grant, revoke, audit.

### The governance model

```sql
-- Grant a principal the ability to call an MCP service
GRANT EXECUTE ON MCP SERVICE catalog.schema.svc TO principal;

-- Revoke is instant, no redeployment needed
REVOKE EXECUTE ON MCP SERVICE catalog.schema.svc FROM principal;
```

Audit actions — `createMcpService`, `updateMcpService`, `mcpCall` — are captured in `system.access.audit` alongside standard UC events.

**Management API**: `/api/2.1/unity-catalog/mcp-services`

### Built-in system services (zero setup)

Seven services in the `system.ai.*` namespace are managed by Databricks — no connection configuration, no credential management. Just grant `EXECUTE` to the identities that need access:

| Service | UC name |
|---|---|
| Slack | `system.ai.slack` |
| GitHub | `system.ai.github` |
| Atlassian (Jira / Confluence) | `system.ai.atlassian` |
| Google Drive | `system.ai.google_drive` |
| Google Calendar | `system.ai.google_calendar` |
| Gmail | `system.ai.gmail` |
| SharePoint | `system.ai.sharepoint` |

Databricks manages the OAuth registration for these providers. No stored credentials, no `http_request()` wiring.

### Tool filtering via service policies

MCP service policies let you restrict which tools a principal can call within a service, and require approval gates for sensitive operations:

- **Allow list**: limit a principal to a specific subset of tools
- **Deny list**: block specific tools while allowing the rest
- **Approval gate**: require human approval before a tool executes

This is access control at the tool level, not just the service level.

---

## Three MCP Server Types

| Type | What it is | Auth model | Use when |
|---|---|---|---|
| **Managed** | Databricks-hosted MCP wrapping built-in data services | OBO or M2M via `DatabricksMCPClient` | Agent needs Genie, Vector Search, UC Functions, or DBSQL |
| **Custom** | Your own MCP server hosted as a Databricks App | OAuth only (OBO or M2M); no PATs | Custom business logic to expose as tools |
| **External** | Third-party MCP servers as UC MCP Services, or proxied through a UC HTTP connection (legacy) | Managed OAuth (UC MCP Service) or Custom HTTP / DCR (connection proxy) | External services; UC governs access |

---

## Decision Tree

```
Agent needs to call a tool
  ├─ Data in Databricks? → MANAGED MCP
  ├─ Custom business logic YOU own? → CUSTOM MCP (Databricks Apps)
  └─ External service?
        ├─ Slack, GitHub, Atlassian, Google, SharePoint? → system.ai.* MCP Service (GRANT EXECUTE)
        ├─ Other third-party with MCP support? → UC MCP Service (catalog.schema.svc)
        └─ Existing UC HTTP connection? → Connection proxy (legacy, still functional)
```

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
| Managed — Genie | `CAN_USE` on Genie space; row filters + column masks on underlying tables |
| Managed — Vector Search | `CAN_SELECT` on VS index |
| Managed — UC Functions | `EXECUTE` privilege on each function |
| Managed — DBSQL | Full UC table/schema/catalog privileges |
| **UC MCP Service** | `EXECUTE` on `catalog.schema.mcp_service`; tool-level allow/deny via service policies |
| External (connection proxy, legacy) | `USE CONNECTION` on the UC HTTP connection |
| Custom | Whatever your tool code enforces (OBO → user identity propagated; M2M → SP identity) |

### UC MCP Services — Recommended Path for External Integrations

MCP Services surface as `catalog.schema.mcp_service` in the UC object hierarchy. The governance workflow is identical to functions and tables:

1. Create or reference an MCP Service (built-in `system.ai.*` or custom via `/api/2.1/unity-catalog/mcp-services`)
2. `GRANT EXECUTE ON MCP SERVICE catalog.schema.svc TO principal`
3. Optionally configure service policies to allow/deny specific tools or add approval gates
4. Agent discovers and calls tools — Databricks handles OAuth token exchange, no credentials in app code
5. All calls audited as `mcpCall` in `system.access.audit`

For the seven built-in services, step 1 is skipped — the service already exists in `system.ai.*`.

### External Connection Proxy — Legacy Path

The connection proxy (`/api/2.0/mcp/external/{connection_name}` + `USE CONNECTION` grant) remains functional for existing integrations. It is not the recommended approach for new work. Migrate to UC MCP Services when the integration supports it.

The proxy governance model: UC checks `USE CONNECTION` before every proxy request. The agent code never touches raw credentials — Databricks injects them server-side. `REVOKE USE CONNECTION` is instant, requires no redeployment, and is audited in `system.access.audit`.

---

## Custom MCP Server — Governance Considerations

Custom MCP servers introduce the **two-proxy problem**: when one Databricks App calls another, Proxy 2 strips the user's token and replaces it with the downstream SP's token. The user's identity is lost at the data plane unless `authorization: disabled` is set on the downstream app.

**Key governance points:**

- `X-Forwarded-Email` is the only reliable identity source in custom MCP servers — set by the proxy, cannot be forged
- `ModelServingUserCredentials()` does NOT work in Databricks Apps — silently falls back to M2M, returning SP identity instead of user
- Each app deployment gets its own SP — grants don't carry over between deployments
- Custom MCP servers use OAuth only (no PATs) and Streamable HTTP transport

For the two-proxy architecture diagram, ASGI middleware patterns, and code examples, see [Proxy Architecture](../identity/proxy-architecture.md) and the [fieldkit custom MCP guide](https://github.com/bhavink/fieldkit).

---

## Related

- [`uc-connections.md`](uc-connections.md) — UC HTTP connections (legacy external MCP proxy pattern)
- [`ai-gateway-patterns.md`](ai-gateway-patterns.md) — AI Gateway and model serving governance; service policies vs guardrails
- [`../identity/`](../identity/) — OBO passthrough, M2M service principals, auth patterns
