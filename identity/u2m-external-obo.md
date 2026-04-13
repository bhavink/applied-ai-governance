# U2M OAuth from External Apps

> Your app runs outside Databricks, but your users are Databricks users. You want `current_user()` = the human's email end-to-end, with UC governance firing per individual identity, not a shared service principal.

## When to Use

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

## How It Differs from Federation

| | U2M OBO (this pattern) | Federation (token exchange) |
|---|---|---|
| Who the user is | Databricks user (has workspace account) | External user (no Databricks account) |
| `current_user()` returns | Human email | SP application UUID |
| Token flow | Databricks OAuth PKCE, user's token forwarded | IdP JWT exchanged for Databricks SP token via RFC 8693 |
| MCP server deployment | `authorization: enabled` (proxy validates user token) | `authorization: disabled` (app manages its own auth) |
| Identity granularity | Individual (per-user row filters) | Role-based (per-group `is_member()` filters) |
| IdP involvement | Transparent (Databricks delegates to workspace IdP) | Explicit (app exchanges IdP JWT for SP token) |
| Audit trail | Human email in platform audit | SP in platform audit, human in app audit |

## Architecture

```
External SPA ──→ CF Worker (CORS proxy) ──→ Databricks MCP App ──→ SQL / Genie / Serving
     |                                            |
     v                                            v
Databricks OAuth (PKCE)                 X-Databricks-Token header
     |                                  (user's original OAuth token)
     v
IdP (Entra/Okta) via SSO
```

The app runs entirely outside Databricks. No PAT. No service principal token shared with the browser.

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

Databricks redirects back to the SPA with an authorization code. The CF Worker (CORS proxy) exchanges the code + PKCE verifier for an access token at the Databricks token endpoint.

```
POST {DATABRICKS_HOST}/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={AUTH_CODE}
&redirect_uri={SPA_ORIGIN}/callback
&client_id={APP_INTEGRATION_CLIENT_ID}
&code_verifier={PKCE_VERIFIER}
```

The CF Worker returns only the `access_token` to the browser. The refresh token is not exposed.

### Step 4: SPA stores token

The SPA stores the access token in `sessionStorage`. Every subsequent MCP tool call includes this token via a custom header (`X-DB-Token` to the CF Worker).

### Step 5: CF Worker calls MCP app

The CF Worker proxies the MCP call to the Databricks App, sending the user's token in two headers:

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

## The Two-Proxy Problem

Two MCP app deployments exist with identical code but different proxy behavior:

| | `mcp-ai-gov-obo` | `mcp-ai-gov-ext` |
|---|---|---|
| `authorization:` | `disabled` | `enabled` |
| Caller | Internal Databricks Apps (Streamlit, etc.) | External clients (CF Workers, SPAs) |
| How user token arrives | `x-forwarded-access-token` injected by the calling app's proxy | `Authorization` header validated by this app's proxy |

**Why two deployments?**

- `authorization: disabled` is required for app-to-app calls. When App A calls App B, both have proxies. If App B's proxy is enabled, it strips App A's forwarded token and replaces it with a proxy-to-proxy credential. The human identity is lost. Disabling the proxy on the receiving app lets the token pass through.
- `authorization: enabled` is required for external callers. Without a proxy, anyone with the app URL could call the MCP server. The proxy validates the caller's Databricks OAuth token and mints a properly scoped OBO token.

Same code, two deployments, different proxy behavior. This is a known platform constraint (GAP 7 in the implementation notes).

## The X-Databricks-Token Workaround

The Databricks Apps proxy mints an OBO token (available as `x-forwarded-access-token`) that should carry the scopes configured in `user_api_scopes`. In practice, the proxy's OBO token does not receive `sql` scope for programmatic API callers, even when `user_api_scopes` includes `sql`. This works correctly for browser-based interactive sessions but fails for server-to-server calls.

**The fix**: send the user's original OAuth token via the `X-Databricks-Token` header. The MCP server reads this header instead of `x-forwarded-access-token` for downstream SQL and Genie calls. The original token carries the full scope set from the app integration configuration.

This is why the CF Worker sends the same token in both `Authorization` (for the proxy) and `X-Databricks-Token` (for the MCP server code).

## Prerequisites

### Databricks Account Console

| # | What | Why |
|---|---|---|
| 1 | **App Integration** (public client) | Registered in Account Console > App Connections. PKCE enabled, no client secret. Redirect URL set to the SPA origin + `/callback`. |
| 2 | **Token TTL** | Configurable from 5 to 1440 minutes in the app integration settings. Default is 60 minutes. |

### Databricks MCP App

| # | What | Why |
|---|---|---|
| 3 | **`authorization: enabled`** in `app.yaml` | Proxy validates external callers' tokens |
| 4 | **`user_api_scopes`** configured | Must include `sql`, `dashboards.genie`, `files.files` (whatever the MCP tools need) |
| 5 | **SQL Warehouse resource** | App needs `CAN_USE` on the warehouse |

### External App (CF Pages / SPA)

| # | What | Why |
|---|---|---|
| 6 | **CORS proxy** (CF Worker, Lambda, etc.) | Browsers cannot call Databricks token endpoint or MCP app directly due to CORS |
| 7 | **Client ID** in SPA config | The app integration's public client ID (safe to embed in browser code) |
| 8 | **MCP URL** in Worker config | The Databricks App URL for the `authorization: enabled` deployment |

### User Grants

| # | What | Why |
|---|---|---|
| 9 | **UC grants** on the target data | Users need `SELECT` on tables, `EXECUTE` on functions, `USE CONNECTION` on connections |
| 10 | **Warehouse access** | Users need `CAN_USE` on the SQL warehouse |

## Key Discoveries (Gotchas)

1. **Proxy OBO token lacks `sql` scope for programmatic callers.** The `x-forwarded-access-token` minted by the proxy does not carry `sql` scope when the caller is a server (CF Worker) rather than a browser. Workaround: `X-Databricks-Token` header with the user's original token.

2. **`authorization: disabled` cannot serve both app-to-app and external clients.** Internal callers need the proxy disabled (two-proxy token stripping). External callers need the proxy enabled (token validation). This is documented as GAP 7. Solution: two deployments of the same code.

3. **Two deployments, same code.** `mcp-ai-gov-obo` (disabled) for internal app-to-app calls. `mcp-ai-gov-ext` (enabled) for external callers. The only difference is the `authorization:` flag in `app.yaml`.

4. **`X-Databricks-Token` bypasses the proxy's OBO token.** The MCP server reads this header directly, using the user's original OAuth token for SQL execution. This preserves `current_user()` = human email.

5. **Token TTL is configurable.** The app integration in Account Console allows 5 to 1440 minutes. For external apps with session-based usage, longer TTLs reduce re-authentication friction.

6. **CORS proxy is mandatory.** Browsers cannot POST to `{host}/oidc/v1/token` or to the Databricks App URL directly. The CF Worker handles both the code exchange and MCP proxying.

7. **Refresh tokens should not reach the browser.** The CF Worker returns only the `access_token` from the code exchange. The refresh token stays server-side (or is discarded in this pattern).

## Related

- [Authorization](authorization.md): OBO, M2M, and Federation token patterns
- [Federation Exchange](federation.md): For external users who are NOT Databricks users
- [Federation Implementation Blueprint](federation-implementation-blueprint.md): Step-by-step recipe for the token exchange pattern
