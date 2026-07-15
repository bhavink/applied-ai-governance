<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/obo-passthrough.md, apps/proxy-architecture.md
  Public docs grounding: https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m
  This file is auto-prepared and human-reviewed before publish.
-->

# U2M OAuth from External Apps

> Your app runs outside Databricks, but your users are Databricks users. You want `current_user()` = the human's email end-to-end, with UC governance firing per individual identity, not a shared service principal.

---

## When to Use This Pattern

- The user calling the external app is already a Databricks user (registered in the workspace via the workspace-configured IdP)
- You want `current_user()` = human email end-to-end (not an SP)
- The external app is NOT running on Databricks (CF Pages, custom SPA, mobile app)
- UC row filters, column masks, and `USE CONNECTION` should fire per individual user
- Browser interaction is available (user can complete an OAuth consent flow)

## When NOT to Use (Use Federation Instead)

- Users are NOT Databricks users (partners, vendors, customers with their own IdP)
- You need role-based access (one SP per role) rather than individual user access
- No browser interaction is possible (pure backend/API)
- You want to decouple external identity from Databricks identity

See [Federation Exchange](federation.md) for the role-based SP pattern.

---

## How It Differs from Federation

| Aspect | U2M OBO (this pattern) | Federation (token exchange) |
|---|---|---|
| Who the user is | Databricks user (has workspace account) | External user (no Databricks account) |
| `current_user()` returns | Human email | SP application UUID |
| Token flow | Databricks OAuth PKCE, user's token forwarded | IdP JWT exchanged for Databricks SP token via RFC 8693 |
| MCP server deployment | `authorization: enabled` (proxy validates user token) | `authorization: disabled` (app manages its own auth) |
| Identity granularity | Individual (per-user row filters) | Role-based (per-group `is_member()` filters) |
| IdP involvement | Transparent (Databricks delegates to workspace IdP) | Explicit (app exchanges IdP JWT for SP token) |
| Audit trail | Human email in platform audit | SP in platform audit, human in app audit |

---

## Architecture

```
External SPA ──→ CORS Proxy (CF Worker / Lambda) ──→ Databricks MCP App ──→ SQL / Genie / Serving
     │                                                       │
     ▼                                                       ▼
Databricks OAuth (PKCE)                            X-Databricks-Token header
     │                                             (user's OAuth token, server-side use)
     ▼
IdP (Entra / Okta) via SSO
```

The app runs entirely outside Databricks. No PAT. No service principal token shared with the browser.

---

## The Flow (5 Steps)

### Step 1: User clicks login

The SPA redirects to the Databricks OIDC authorize endpoint with a PKCE code challenge. No client secret involved.

```
GET {DATABRICKS_HOST}/oidc/v1/authorize
  ?response_type=code
  &client_id={APP_INTEGRATION_CLIENT_ID}
  &redirect_uri={SPA_ORIGIN}/callback
  &scope=all-apis offline_access
  &code_challenge={SHA256_HASH}
  &code_challenge_method=S256
```

### Step 2: Databricks redirects to IdP

Databricks delegates to the workspace's configured IdP (Entra, Okta, etc.). If the user is already SSO'd, this is seamless. Otherwise they see the IdP login page.

### Step 3: Redirect back, exchange code for token

Databricks redirects back to the SPA with an authorization code. The CORS proxy exchanges the code + PKCE verifier for an access token at the Databricks token endpoint.

```
POST {DATABRICKS_HOST}/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={AUTH_CODE}
&redirect_uri={SPA_ORIGIN}/callback
&client_id={APP_INTEGRATION_CLIENT_ID}
&code_verifier={PKCE_VERIFIER}
```

The CORS proxy returns only the `access_token` to the browser. The refresh token is held server-side or discarded.

### Step 4: SPA stores token

The SPA stores the access token in `sessionStorage`. Every subsequent MCP tool call includes this token in the request header sent to the CORS proxy.

### Step 5: CORS proxy calls MCP app

The CORS proxy forwards the MCP call to the Databricks App, sending the user's token in two headers:

```
POST {MCP_APP_URL}/mcp
Content-Type: application/json
Authorization: Bearer {USER_TOKEN}
X-Databricks-Token: {USER_TOKEN}

{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "check_identity"}}
```

- `Authorization` is consumed by the Databricks Apps proxy (validates the caller, mints the OBO token)
- `X-Databricks-Token` is read by the MCP server code for downstream SQL/Genie calls

UC governance fires at the SQL engine level. `current_user()` = the human's email. Row filters, column masks, and connection privileges all evaluate against the individual.

---

## The Two-Deployment Pattern

App-to-app calls (one Databricks App calling another) and external calls (a non-Databricks client calling a Databricks App) need different proxy configurations on the receiving app. The standard approach is **two deployments of the same code**, each with a different `authorization` setting in `app.yaml`.

| Deployment role | `authorization:` setting | Caller type | How the user token arrives |
|---|---|---|---|
| App-to-app receiver | `disabled` | Internal Databricks Apps (Streamlit, FastAPI) | `x-forwarded-access-token` injected by the *calling* app's proxy |
| External-client receiver | `enabled` | External clients (CORS proxy, partner SPA, mobile) | `Authorization` header validated by *this* app's proxy |

Why two deployments?

- `authorization: disabled` is required for app-to-app calls. When App A calls App B and both have proxies enabled, the receiving proxy may replace the inbound token with a proxy-to-proxy credential. Disabling the proxy on the receiving app preserves the human identity end-to-end.
- `authorization: enabled` is required for external callers. Without proxy enforcement, anyone with the app URL could reach the MCP endpoint. The proxy validates the caller's Databricks OAuth token and mints a properly scoped OBO token.

Same code, two deployments, different proxy behavior.

---

## The X-Databricks-Token Header Pattern

The Databricks Apps proxy mints an OBO token on each request, available to the app code as `x-forwarded-access-token`. By default this token carries a minimal identity scope set (`openid`, `email`, `profile`, `iam.current-user:read`, and similar) — enough for the Genie Conversation API and Model Serving calls, but not for the Statement Execution API or other UC-scoped calls. Extending what this token carries requires configuring the App Integration's scopes through the console's User Authorization step (see Prerequisites below) rather than through CLI updates alone.

For programmatic callers (server-to-server flows like a CORS proxy invoking the MCP app), a more direct pattern is often simpler: send the user's original Databricks OAuth token — the one issued in Step 3 above, requested with the scopes the SPA needs at the App Integration level — in a custom header, and have the MCP server use that token directly for downstream SQL or Genie calls. The header name `X-Databricks-Token` is a common convention.

```python
# In the MCP server code
def downstream_token(headers: dict) -> str:
    # Prefer caller-provided token for server-to-server flows
    if t := headers.get("X-Databricks-Token"):
        return t
    # Fall back to proxy-minted token for browser flows
    return headers.get("x-forwarded-access-token", "")
```

This keeps `current_user()` = the human's email for both interactive and programmatic callers.

---

## Prerequisites

### Databricks Account Console

| # | What | Why |
|---|---|---|
| 1 | **App Integration** (public client) | Registered in Account Console → App Connections. PKCE enabled, no client secret. Redirect URL set to the SPA origin + `/callback`. |
| 2 | **Token TTL** | Configurable from 5 to 1440 minutes in the app integration settings. Default is 60 minutes. |
| 3 | **Scopes via User Authorization** | Configure requested scopes through the App Integration's **User Authorization** step in the console, not through CLI updates alone. The console flow is what puts the scopes into the issued token's `scope` claim; a CLI-only update records the scopes on the integration but the token used downstream won't reflect them. |

### Databricks MCP App

| # | What | Why |
|---|---|---|
| 4 | **`authorization: enabled`** in `app.yaml` | Proxy validates external callers' tokens |
| 5 | **`user_api_scopes`** configured | Set the full list up front rather than adding scopes one at a time as calls fail: `sql` for Statement Execution, `dashboards.genie` and `genie` together for the Genie Conversation API (both are required on Azure), `unity-catalog` for calls through the External MCP connection proxy, `files.files` for Volumes access — whatever the MCP tools need. |
| 6 | **SQL Warehouse resource** | App needs `CAN_USE` on the warehouse |

### External App (SPA)

| # | What | Why |
|---|---|---|
| 7 | **CORS proxy** (CF Worker, Lambda, etc.) | Browsers cannot call Databricks token endpoint or MCP app directly due to CORS |
| 8 | **Client ID** in SPA config | The app integration's public client ID (safe to embed in browser code) |
| 9 | **MCP URL** in proxy config | The Databricks App URL for the `authorization: enabled` deployment |

### User Grants

| # | What | Why |
|---|---|---|
| 10 | **UC grants** on the target data | Users need `SELECT` on tables, `EXECUTE` on functions, `USE CONNECTION` on connections |
| 11 | **Warehouse access** | Users need `CAN_USE` on the SQL warehouse |

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| External SPA calling Databricks MCP | OAuth PKCE with public client ID; CORS proxy for token exchange and MCP forwarding |
| App-to-app + external client on the same code base | Two deployments — `authorization: disabled` for internal, `authorization: enabled` for external |
| Programmatic callers needing user-level SQL | `X-Databricks-Token` header read by MCP server for downstream calls |
| Long-lived browser sessions | App integration TTL up to 1440 minutes; combine with refresh tokens server-side |
| Audit trail to human email | UC grants + row filters per individual; `current_user()` resolves to the human |
| Effective scopes on the OAuth token (sql, genie, unity-catalog) | Configure via the App Integration's console User Authorization step, not CLI updates alone |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Browser holding a refresh token | Refresh tokens stay server-side in the CORS proxy; SPA gets only the access token |
| Single deployment serving both internal and external callers | Two deployments with different `authorization` settings |
| Service principal shared with the browser | Per-user OBO; never expose SP credentials in client code |
| Direct browser → Databricks token endpoint | CORS proxy required — browsers cannot reach the token endpoint directly |
| `ModelServingUserCredentials()` inside a Databricks App | This class only works in Model Serving — it silently falls back to M2M in Apps, returning the SP identity instead of the user. In Apps, read `X-Forwarded-Access-Token` from the proxy header instead. |

---

## The Two-Proxy Problem (App-to-App)

When App A calls App B and both have `authorization: enabled`, App B's proxy intercepts the inbound token and **substitutes its own SP token**. The human's identity is lost at the data plane — `current_user()` in App B's SQL calls returns the SP, not the user.

**The correct fix is not to pass the user token in a custom header through App B's proxy.** Instead:

- Set `authorization: disabled` on App B when it is called only from other apps (never from a browser or external client).
- If App B must serve both app-to-app and external callers, use two deployments (one with `auth: disabled`, one with `auth: enabled`) — same code, different proxy settings.
- When you need the user identity inside App B for SQL but cannot disable auth, read `X-Forwarded-Email` from the header for identity, then use M2M (`WorkspaceClient()`) for the SQL call with user impersonation enforced at the UC layer via row filters on `current_user()`.

---

## Gotchas

| Issue | Detail |
|---|---|
| Scope changes need re-consent | Adding scopes to the App Integration doesn't apply to tokens already issued to a user. The user needs to complete the OAuth flow again (or an admin can pre-authorize on the user's behalf) before the new scopes take effect in their token. |
| CLI-only scope configuration is incomplete | Setting scopes only through the CLI records them on the integration, but the console's User Authorization step is what puts them into the issued token's `scope` claim. Use the console flow when the token needs to carry effective scopes for downstream calls. |
| Use `httpx`/`requests` directly for the forwarded token | The Databricks SDK reads `DATABRICKS_HOST`/`DATABRICKS_TOKEN` from the environment, which on a Databricks App points at the app's own SP credentials. Making the SQL/Genie call with a plain HTTP client and an explicit `Authorization: Bearer {token}` header avoids that conflict. |

---

## Related

- [`authorization.md`](authorization.md) — OBO, M2M, and Federation token patterns
- [`federation.md`](federation.md) — For external users who are NOT Databricks users
- [`federation-implementation-blueprint.md`](federation-implementation-blueprint.md) — Step-by-step recipe for the token exchange pattern
- [`byoidp-peruser-federation.md`](byoidp-peruser-federation.md) — Per-user identity from an external app with a customer-owned IdP (this U2M pattern is its no-JWKS fallback)
- [`proxy-architecture.md`](proxy-architecture.md) — How the Databricks Apps proxy mints OBO tokens

---

## Public References

- [Databricks OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m)
- [Databricks Apps authentication](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth)
- [App integrations and PKCE](https://docs.databricks.com/aws/en/admin/account-settings-e2/idp-federation)
