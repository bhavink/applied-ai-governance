# MCP Governance — Server Types, Tool Selection, and Auth Patterns

> **TL;DR**: Databricks supports three MCP server types: Managed, Custom, and External. All are enforced by Unity Catalog. MCP-first is the recommended tool selection strategy — agents discover tools dynamically at runtime rather than hardcoding definitions.

---

## Three MCP Server Types

| Type | What it is | Auth model | Use when |
|---|---|---|---|
| **Managed** | Databricks-hosted MCP wrapping built-in data services | OBO or M2M via `DatabricksMCPClient` | Agent needs Genie, Vector Search, UC Functions, or DBSQL |
| **Custom** | Your own MCP server hosted as a Databricks App | OAuth only (OBO or M2M); no PATs | Custom business logic to expose as tools |
| **External** | Third-party MCP servers proxied through a UC HTTP connection | Managed OAuth / Custom HTTP / DCR | External services; UC governs access |

---

## Decision Tree

```
Agent needs to call a tool
  ├─ Data in Databricks? → MANAGED MCP
  ├─ Custom business logic YOU own? → CUSTOM MCP (Databricks Apps)
  └─ External service? → EXTERNAL MCP (UC HTTP connection)
        ├─ Provider in Marketplace? → Managed OAuth
        ├─ Any HTTP MCP? → Custom HTTP connection
        └─ Server supports OAuth DCR? → Dynamic Client Registration
```

---

## Tool Selection Priority (MCP-First)

| Priority | Tool Type | Auth model | Governance | Best for |
|---|---|---|---|---|
| 1 | **Managed MCP server** | OBO or SP (auto) | UC privileges | Default choice — dynamic tool discovery |
| 2 | **External MCP server** | `USE CONNECTION` + stored creds | `USE CONNECTION` privilege | GitHub, Glean, Jira, SaaS with MCP |
| 3 | **Custom MCP server** | Custom (your server's auth) | Code-level + connection | Internal APIs, custom integrations |
| 4 | **UC Function** | Caller's identity (OBO) or SP | `EXECUTE` privilege | Deterministic computations, data lookups |
| 5 | **Retriever tool (Vector Search)** | SP (M2M) or OBO | `SELECT` on VS index | Document Q&A, semantic search |
| 6 | **Agent-as-tool** | Inherits parent's auth | Same as parent | Multi-agent orchestration |
| 7 | **Custom Python function** | Defined in code | Code-level | Last resort — ungoverned |

**Why MCP-first?** MCP servers provide standardized tool discovery, schema validation, and auth delegation. Agents dynamically discover available tools at runtime instead of hardcoding tool definitions.

---

## UC Permissions by Server Type

| Server type | What UC enforces |
|---|---|
| Managed — Genie | `CAN_USE` on Genie space; row filters + column masks on underlying tables |
| Managed — Vector Search | `CAN_SELECT` on VS index |
| Managed — UC Functions | `EXECUTE` privilege on each function |
| Managed — DBSQL | Full UC table/schema/catalog privileges |
| External | `USE CONNECTION` on the UC HTTP connection |
| Custom | Whatever your tool code enforces (OBO → user identity propagated; M2M → SP identity) |

### External Connection Tools — Agent Framework Integration

External connection tools are the Agent Framework's native path for third-party API access. The flow:

1. Create UC HTTP connection (stores credentials)
2. Mark as MCP connection (enables `/api/2.0/mcp/external/{conn_name}` proxy)
3. `GRANT USE CONNECTION` to authorized identities
4. Agent discovers tools from the external MCP server via the proxy

The governance model: UC checks `USE CONNECTION` before every proxy request. The agent code never touches raw credentials — Databricks injects them server-side. `REVOKE USE CONNECTION` is instant, requires no redeployment, and is audited in `system.access.audit`.

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

- [`uc-connections.md`](uc-connections.md) — UC HTTP connections for external MCP
- [`ai-gateway-patterns.md`](ai-gateway-patterns.md) — AI Gateway and model serving governance
- [`../identity/`](../identity/) — OBO passthrough, M2M service principals, auth patterns
