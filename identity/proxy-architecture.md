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
| `X-Forwarded-Access-Token` | OBO token for downstream API calls (Genie, Agent Bricks). **Does NOT carry `sql` scope** — regardless of OAuth integration configuration. | Medium |
| `X-Forwarded-Groups` | Group membership for `is_member()` evaluation in row filters. | High |

**Critical constraint**: `X-Forwarded-Access-Token` is a minimal OIDC identity token. Adding `sql` to `user_authorized_scopes` does NOT fix this — the platform issues a minimal token regardless. SQL operations require M2M (`WorkspaceClient()`) with identity from `X-Forwarded-Email`.

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

## Gotchas

| Issue | Governance impact |
|---|---|
| `ModelServingUserCredentials()` doesn't work in Apps | Silently falls back to M2M — returns SP identity, not user. Audit records will show the wrong identity. |
| `authorization: disabled` means no auth at all | Unauthenticated requests reach your app. Only use on downstream apps behind another proxy. |
| Two different SPs for two apps | Each deployment gets a new SP. Grants don't carry over — grant both SPs separately. |
| Token refresh doesn't pick up new scopes | Adding scopes to an OAuth integration doesn't affect existing tokens. Requires app delete + recreate to force re-authorization. |

---

## Related

- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [OAuth Scopes Reference](oauth-scopes-reference.md) — Scope governance and blast-radius tiers
- [U2M OBO from external apps](u2m-external-obo.md) — External SPA + Databricks OAuth PKCE

For complete header reference, hop-by-hop traces, ASGI middleware patterns, and code examples, see the [fieldkit proxy architecture guide](https://github.com/bhavink/fieldkit).
