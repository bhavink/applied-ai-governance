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

---

## Custom MCP Server — Auth Patterns

### The Two-Proxy Problem

When a Databricks App (Proxy 1) calls a custom MCP App (Proxy 2), both proxies intervene independently:

```
User browser
    ↓
[main-app proxy]        ← Proxy 1: injects Token A (user's token)
    ↓  Authorization: Bearer {Token A}
[custom-mcp proxy]      ← Proxy 2: STRIPS Authorization header
    ↓  injects X-Forwarded-Access-Token (Token B — MCP app's SP token)
    ↓  injects X-Forwarded-Email (correctly set to user's email)
server/main.py (FastMCP)
```

Token B's `sub` claim is the MCP SP's UUID — not the user. `ModelServingUserCredentials()` reads Model Serving's internal request context (does not exist in Apps) and silently falls back to M2M, returning the SP identity instead of the user.

**Solution**: Use `X-Forwarded-Email` for identity — set by Proxy 2 from Token A's validated identity. Cannot be forged by the calling app.

### OBO Identity Extraction

```python
# X-Forwarded-Email is proxy-injected and cannot be forged by the calling app.
# Use pure ASGI middleware (NOT BaseHTTPMiddleware) — BaseHTTPMiddleware runs
# call_next in a new asyncio task, breaking ContextVar inheritance.

import contextvars
from starlette.types import ASGIApp, Receive, Scope, Send

_request_caller: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_caller", default=""
)

class ExtractTokenMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http":
            headers = {k.lower(): v for k, v in scope.get("headers", [])}
            caller_email = headers.get(b"x-forwarded-email", b"").decode("utf-8")
            token = _request_caller.set(caller_email)
            try:
                await self.app(scope, receive, send)
            finally:
                _request_caller.reset(token)
            return
        await self.app(scope, receive, send)

def _caller_email() -> str:
    return _request_caller.get("")
```

### M2M Pattern

```python
from databricks.sdk import WorkspaceClient

def _m2m_client() -> WorkspaceClient:
    # Runs as APP SERVICE PRINCIPAL.
    # SDK auto-discovers DATABRICKS_CLIENT_ID/SECRET from env vars.
    return WorkspaceClient()
```

### Critical: `ModelServingUserCredentials()` Does Not Work in Databricks Apps

`ModelServingUserCredentials()` only works inside Databricks Model Serving. In a Databricks App context it silently falls back to M2M, returning the SP identity rather than the calling user. Do not use it for OBO identity in Apps. Read `X-Forwarded-Email` instead.

---

## URL Patterns Cheatsheet

```
# Managed MCP — Databricks-hosted servers
Genie:          {host}/api/2.0/mcp/genie/{genie_space_id}
Vector Search:  {host}/api/2.0/mcp/vector-search/{catalog}/{schema}/{index_name}
UC Functions:   {host}/api/2.0/mcp/functions/{catalog}/{schema}
DBSQL:          {host}/api/2.0/mcp/sql

# External MCP — proxied through UC HTTP connection
External:       {host}/api/2.0/mcp/external/{uc_connection_name}

# Custom MCP — your server hosted on Databricks Apps
Custom:         https://{app-url}/mcp
```

---

## Transport

All Databricks MCP servers use **Streamable HTTP** transport. WebSocket and stdio-based MCP servers are not supported.

---

## Related

- [`uc-connections.md`](uc-connections.md) — UC HTTP connections for external MCP
- [`ai-gateway-patterns.md`](ai-gateway-patterns.md) — AI Gateway and model serving governance
- [`../identity/`](../identity/) — OBO passthrough, M2M service principals, auth patterns
