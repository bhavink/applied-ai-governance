<!--
  Synced from databricks-fieldkit on 2026-07-07
  Sources: apps/proxy-architecture.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth
  This file is auto-prepared and human-reviewed before publish.
-->

# Databricks Apps Proxy Architecture

> **TL;DR**: Every Databricks App has an invisible reverse proxy that authenticates users, strips the original Authorization header, and injects `X-Forwarded-*` identity headers. The proxy is the single source of truth for caller identity. When one app calls another app (app-to-app), a second proxy intervenes — creating the "two-proxy problem" where the user's token is replaced by the second app's SP token.

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
| `X-Forwarded-Access-Token` | OBO token for downstream API calls (Genie, Agent Bricks). Carries `sql` scope **only when the user has completed UI User Authorization** for the `sql` scope — otherwise a minimal OIDC identity token. | Medium |
| `X-Forwarded-Groups` | Group membership for `is_member()` evaluation in row filters. | High |
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

## Supported Frameworks

The proxy sits in front of any Python web framework the app runs. Supported: **Streamlit**, **Gradio**, **Flask**, **Dash**, and **Shiny** (Python). The proxy behavior — header injection, OBO minting, authorization enforcement — is identical regardless of framework.

---

## App Status Lifecycle

| State | Meaning |
|---|---|
| `Running` | App is healthy and serving traffic. |
| `Stopped` | App has been manually stopped or scaled to zero. |
| `Deploying` | App is starting up or redeploying. Headers are not yet injected. |
| `Crashed` | App exited unexpectedly. Check logs before re-examining auth behavior — crashes during startup can produce misleading 502s. |

---

## Gotchas

| Issue | Governance impact |
|---|---|
| `ModelServingUserCredentials()` doesn't work in Apps | Silently falls back to M2M — returns SP identity, not user. Audit records will show the wrong identity. |
| OBO SQL: use httpx/requests, not the SDK | `WorkspaceClient()` reads `DATABRICKS_TOKEN` env var (the SP's M2M credential) and overrides the OBO token. Use `httpx` or `requests` directly with the `X-Forwarded-Access-Token` value as the Bearer token. |
| `authorization: disabled` means no auth at all | Unauthenticated requests reach your app. Only use on downstream apps behind another proxy. |
| Two different SPs for two apps | Each deployment gets a new SP. Grants don't carry over — grant both SPs separately. |
| Token refresh doesn't pick up new scopes | Adding scopes to an OAuth integration doesn't affect existing tokens. Requires app delete + recreate to force re-authorization. |

---

## Related

- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [OAuth Scopes Reference](oauth-scopes-reference.md) — Scope governance and blast-radius tiers
- [U2M OBO from external apps](u2m-external-obo.md) — External SPA + Databricks OAuth PKCE

For complete header reference, hop-by-hop traces, ASGI middleware patterns, and code examples, see the [fieldkit proxy architecture guide](https://github.com/bhavink/fieldkit).
