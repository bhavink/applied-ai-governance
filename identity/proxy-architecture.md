<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: apps/proxy-architecture.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/auth
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/key-concepts
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/http-headers
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/networking
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/observability
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/cicd-github-actions
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/embed
  This file is auto-prepared and human-reviewed before publish.
-->

# Databricks Apps Proxy Architecture

> **TL;DR**: Every Databricks App has an invisible reverse proxy that authenticates users, strips the original Authorization header, and injects `X-Forwarded-*` identity headers. The proxy is the single source of truth for caller identity. When one app calls another app (app-to-app), a second proxy intervenes — creating the "two-proxy problem" where the user's token is replaced by the second app's SP token. External clients connecting directly (for example, MCP-based coding assistants) need `authorization: enabled` so the proxy can validate the session and inject identity headers.

---

## Why This Matters for Governance

The proxy determines **which identity** downstream services see. Misconfigure it, and:

- UC row filters fire as the SP instead of the human (data leaks to the wrong role)
- Audit records show the SP UUID instead of the human who triggered the action
- `current_user()` returns the wrong value, and governance fails silently

Every AI app architecture decision — OBO vs M2M, Genie vs direct SQL, app-to-app vs external client — flows through the proxy's identity model.

---

## Identity Headers — Governance Implications

| Header | Governance role | Trust level |
|---|---|---|
| `X-Forwarded-Email` | **Primary identity** for audit and access control. Cannot be forged when proxy is enabled. | High |
| `X-Forwarded-User` | `{user_id}@{workspace_id}` composite identifier; same provenance as email. | High |
| `X-Forwarded-Groups` | Group membership for `is_member()` evaluation in row filters. | High |
| `X-Forwarded-Access-Token` | OBO token for downstream API calls (Genie, Agent Bricks). Carries `sql` scope **only when the user has completed UI User Authorization** for the `sql` scope — otherwise a minimal OIDC identity token. | Medium |
| `X-Forwarded-Preferred-Username` | Display name from the user's profile; informational only. | High |
| `X-Databricks-Org-Id` | Workspace ID; informational. | Informational |
| `X-Request-Id` | UUID injected per request by the proxy for distributed tracing. Use for correlation across logs and downstream services. | Low |

**SQL scope via User Authorization**: When a user completes the UI-driven OAuth authorization flow and grants the `sql` scope, the proxy mints a real OBO JWT. In this case `X-Forwarded-Access-Token` carries SQL scope, and `current_user()` in a SQL warehouse returns the **human user's email** — not the SP. This is the only path to true per-user SQL OBO through the proxy.

**When `sql` scope is not authorized**: The proxy issues a minimal OIDC identity token. SQL operations must use M2M (`WorkspaceClient()`) with identity sourced from `X-Forwarded-Email`.

**OBO SQL gotcha**: Use `httpx` or `requests` directly with `X-Forwarded-Access-Token` as the Bearer token for SQL calls — do NOT use the `WorkspaceClient()` SDK. The SDK reads `DATABRICKS_TOKEN` from the environment, which is the app's SP M2M credential, and will override the OBO token.

---

## The Two-Proxy Problem

When one Databricks App calls another, both have proxies. With `authorization: enabled` on the downstream app (the default), Proxy 2 **strips the upstream token and replaces it with its own SP token**. The user's identity is lost at the data plane.

| Downstream setting | What happens | Identity seen by UC |
|---|---|---|
| `authorization: enabled` (default) | Proxy 2 strips Authorization, replaces X-Forwarded-Access-Token | **Downstream SP** — user identity lost |
| `authorization: disabled` | Proxy 2 is a passthrough — all headers preserved | **Upstream user** — identity preserved |

### Governance tradeoff

| Scenario | Correct setting | Why |
|---|---|---|
| App-to-app calls | `auth: disabled` on downstream | Preserves upstream user identity for UC governance |
| Browser-facing apps | `auth: enabled` | Proxy handles OAuth SSO; without it, no authentication |
| External MCP clients (Claude Code, Cursor) | `auth: enabled` | Proxy validates OAuth and injects identity headers |

**You cannot serve both app-to-app and external-client paths with one deployment.** The solution: deploy the same code twice — one with auth disabled (app-to-app), one with auth enabled (external/browser). Both need separate SP grants.

---

## External Client Path — MCP Clients (Claude Code, Cursor, MCP Inspector)

When an external client connects directly to a Databricks App — typically a custom MCP server — there is only one proxy in the path and no upstream app:

```
External client → mcp-remote (OAuth PKCE) → Databricks Apps proxy → your app (port 8000)
```

`authorization: enabled` (the default) is the correct setting here: it lets the proxy validate the OAuth token and inject `X-Forwarded-Email` for the calling user. `authorization: disabled` on this same deployment leaves the proxy as a pure passthrough — no identity header gets injected, and any OBO-based tool call has no identity to work from.

Because a single deployment can't serve both app-to-app and external-client traffic with one `authorization` setting, pick one of these patterns:

| Approach | Pattern |
|---|---|
| Two deployments | Deploy the same code twice under different app names — one with `authorization: disabled` for app-to-app calls, one with `authorization: enabled` (default) for external clients and browsers. Grant permissions on both service principals. |
| Token fallback in middleware | Keep `authorization: disabled` and add middleware that decodes the Bearer JWT's `email`/`sub` claim when `X-Forwarded-Email` is empty. This moves token-validation responsibility into the app. |
| Internal routing | Keep `authorization: enabled` on the downstream app and have the upstream app call it over an internal service URL instead of the public URL, avoiding the second proxy hop. Requires additional networking configuration. |

---

## Design Rationale

**Prefer `X-Forwarded-Email` over parsing the Bearer JWT.** The header is set by the platform and cannot be forged by the calling app when the proxy is enabled, whereas the token's `sub` claim may point to a service principal rather than the human. Decoding the JWT is a valid pattern when the proxy can't inject headers (for example, `authorization: disabled` with no upstream proxy), but it takes on manual token-validation responsibility.

**Use M2M for SQL alongside identity from the header.** The identity/authorization split — read `X-Forwarded-Email` for *who* is calling, then execute SQL with `WorkspaceClient()` (the app SP) using an explicit `WHERE` clause matching the caller — reproduces the effect of a UC row filter without requiring the `sql` OBO scope on the user's token.

**Use pure ASGI middleware, not `BaseHTTPMiddleware`.** Starlette's `BaseHTTPMiddleware` runs `call_next()` in a separate `asyncio.Task`, and Python `ContextVar` values do not propagate across task boundaries. Setting a `ContextVar` before `call_next()` means the downstream route handler won't see it. Pure ASGI middleware that calls `self.app(scope, receive, send)` directly keeps everything in the same task:

```python
# INCORRECT — ContextVar lost across task boundary
class BadMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        _request_caller.set("alice@example.com")
        response = await call_next(request)  # new task — ContextVar gone
        return response

# CORRECT — ContextVar preserved in same task
class GoodMiddleware:
    def __init__(self, app): self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            _request_caller.set("alice@example.com")
            await self.app(scope, receive, send)  # same task
```

---

## Supported Frameworks

The proxy sits in front of any supported web framework the app runs. Python: **Streamlit**, **Gradio**, **Flask**, **Dash**, **Shiny**. Node.js: **React**, **Angular**, **Svelte**, **Express**. Proxy behavior — header injection, OBO minting, authorization enforcement — is identical regardless of framework or language.

Reading `X-Forwarded-Access-Token` per framework:

```python
# Streamlit
import streamlit as st
user_access_token = st.context.headers.get('x-forwarded-access-token')

# Gradio (auto-injects request)
import gradio as gr
def query_fn(message, history, request: gr.Request):
    access_token = request.headers.get("x-forwarded-access-token")

# Flask / Dash
from flask import request
user_token = request.headers.get('x-forwarded-access-token')

# Shiny
user_token = session.http_conn.headers.get('x-forwarded-access-token')
```

```javascript
// Express (Node.js)
const userAccessToken = req.header('x-forwarded-access-token');
```

> Headers are only injected inside a running Databricks App. When testing locally, simulate or manually include them.

---

## App Authorization Model — Two Identities

Every app has two complementary identity models, usable independently or together:

| Model | Identity | Use cases |
|---|---|---|
| App authorization (SP) | The app's dedicated service principal | Background tasks, shared configuration, logging, calls to other services |
| User authorization (OBO, Public Preview) | The current user's identity via the forwarded token | UC table queries with row filters, fine-grained permission enforcement |

The app SP's credentials are auto-injected as environment variables, and the SDK picks them up automatically via unified auth:

```python
import os
client_id = os.getenv('DATABRICKS_CLIENT_ID')          # auto-injected
client_secret = os.getenv('DATABRICKS_CLIENT_SECRET')   # auto-injected
```

**User authorization scopes** — an app declares which scopes it needs, and users consent on first access:

| Scope | Grants |
|---|---|
| `sql` | SQL warehouse access on behalf of the user |
| `dashboards.genie` | Genie Space access on behalf of the user |
| `files.files` | UC Volumes access on behalf of the user |
| `iam.current-user:read` | Basic identity (default) |
| `iam.access-control:read` | Access control read (default) |

Configure scopes via the workspace UI: app → **Authorization** tab → **User authorization** → **+Add scope**. Workspace admins can restrict which scopes developers may add under Settings → Development → Apps → **Restrict OAuth scopes for apps to selected values**.

---

## Declared Resources

Apps declare their dependencies in `databricks.yml` under `resources`: SQL warehouse, Job, Model serving endpoint, Genie Space, Secret, Volume. For a Databricks service without a supported resource type, inject credentials via a Unity Catalog–managed secret.

---

## Telemetry, CI/CD, and Embedding

Apps support configuring telemetry to collect traces, logs, and metrics in Unity Catalog — see [App telemetry](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/observability). CI/CD is supported via GitHub Actions and Databricks Asset Bundles — see [CI/CD for apps](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/cicd-github-actions). Apps can also be embedded in external websites — see [Embed apps](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/embed).

## Workspace Tier Requirement

Databricks Apps requires a **Premium tier** workspace; it cannot be deployed to standard-tier workspaces.

## Compliance Security Profile

Apps is supported under the compliance security profile. Workspaces with the compliance security profile enabled require a workspace admin to enable Apps on the Previews page first.

---

## App Status Lifecycle

| State | Billable | Meaning |
|---|---|---|
| `Running` | Yes | App is healthy and serving traffic. |
| `Stopped` | No | Configuration and environment preserved; restartable without reconfiguration. |
| `Deploying` | No | App is starting up or redeploying. Headers are not yet injected. |
| `Crashed` | No | App exited unexpectedly. Check logs before re-examining auth behavior — startup failures can produce misleading 502s. |

---

## Gotchas

| Issue | Governance impact |
|---|---|
| `ModelServingUserCredentials()` doesn't work in Apps | Silently falls back to M2M — returns SP identity, not user. Audit records will show the wrong identity. |
| OBO SQL: use httpx/requests, not the SDK | `WorkspaceClient()` reads `DATABRICKS_TOKEN` env var (the SP's M2M credential) and overrides the OBO token. Use `httpx` or `requests` directly with the `X-Forwarded-Access-Token` value as the Bearer token. |
| `authorization: disabled` means no auth at all | Unauthenticated requests reach your app. Only use on downstream apps behind another proxy. |
| Two different SPs for two apps | Each deployment gets a new SP. Grants don't carry over — grant both SPs separately. |
| Token refresh doesn't pick up new scopes | Adding scopes to an OAuth integration doesn't affect existing tokens. Requires app delete + recreate to force re-authorization. |
| Empty `X-Forwarded-Email` | Indicates either `authorization: disabled` with no upstream proxy setting the header, or an unauthenticated request. Treat this as "no verified identity," never as an anonymous-but-trusted caller. |
| External MCP clients need `authorization: enabled` | A client using `mcp-remote` sends a Bearer token but relies on the proxy to validate it and inject `X-Forwarded-Email`. With `authorization: disabled`, no upstream proxy performs that validation, so OBO-based tools have no identity to work from. |
| User authorization needs workspace admin enablement | User authorization (OBO scopes) is Public Preview. A workspace admin must enable it before developers can add scopes to an app, and existing apps must be restarted after the feature is toggled. |
| Scope consent is irrevocable by end users | Once a user consents to app scopes, only a workspace admin can manage or revoke that consent. Admins can pre-consent on behalf of users via workspace Settings → Development → Apps. |
| In-memory state does not survive restarts | Use UC tables, Workspace files, UC Volumes, or Lakebase for anything that needs to persist across app restarts. |
| App URL is immutable | The URL format `<app-name>-<workspace-id>.<region>.databricksapps.com` is fixed at creation. Create a new app to get a different URL. |
| Legacy regional workspace URLs | Databricks Apps requires OAuth, so use the standard workspace URL rather than a legacy regional URL. |

---

## Related

- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [OAuth Scopes Reference](oauth-scopes-reference.md) — Scope governance and blast-radius tiers
- [U2M OBO from external apps](u2m-external-obo.md) — External SPA + Databricks OAuth PKCE
- [Databricks Apps auth](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/auth) — Platform documentation on the proxy, headers, and authorization model
- [Databricks Apps key concepts](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/databricks-apps/key-concepts)
