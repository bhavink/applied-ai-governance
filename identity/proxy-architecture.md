# Databricks Apps Proxy Architecture

> **TL;DR**: Every Databricks App has an invisible reverse proxy that authenticates users, strips the original Authorization header, and injects `X-Forwarded-*` identity headers. The proxy is the single source of truth for caller identity. When one app calls another app (app-to-app), a second proxy intervenes — creating the "two-proxy problem" where the user's token is replaced by the second app's SP token. The solution is `authorization: disabled` on the downstream app + reading `X-Forwarded-Email` for identity. External clients (Claude Code, Cursor) connecting directly have the inverse problem: they need `authorization: enabled` so the proxy injects identity headers.

---

## What the proxy does

Every Databricks App gets an **automatic reverse proxy** managed by the platform. You don't deploy it, configure it, or see it in your code. It sits between the internet and your app process.

```
Internet --> [Databricks Apps Proxy] --> your app (port 8000)
```

The proxy does three things:

1. **Authenticates the caller** — validates the OAuth session cookie (browser) or Bearer token (API call)
2. **Injects identity headers** — adds `X-Forwarded-*` headers your app can read
3. **Strips the original Authorization header** — replaces it with the app's own SP token

Your app never sees the user's original OAuth token. It sees proxy-injected headers.

---

## Proxy-injected headers — complete reference

Set by the proxy on every authenticated request. Your app reads these from the incoming request — you do not send them.

| Header | Example value | What it is | Trust level |
|---|---|---|---|
| `X-Forwarded-Email` | `alice@example.com` | Caller's email from the validated OAuth token | **High** — set by proxy from authenticated identity. Cannot be forged by the calling app. **Use this for identity.** |
| `X-Forwarded-User` | `8362910284@1516413757355523` | `{user_id}@{workspace_id}` | High — same provenance as email |
| `X-Forwarded-Preferred-Username` | `Alice Example` | Display name from user's profile | High — informational |
| `X-Forwarded-Access-Token` | `eyJraWQi...` (JWT) | Minimal OIDC identity token issued by the proxy | Medium — see constraints below |
| `X-Forwarded-Groups` | `group_a,group_b` | Workspace groups the user belongs to | High — from validated token claims |
| `X-Databricks-Org-Id` | `1516413757355523` | Workspace ID | Informational |
| `X-Forwarded-For` | `203.0.113.42` | Client IP address | Standard proxy header |
| `X-Forwarded-Proto` | `https` | Original protocol | Standard proxy header |
| `X-Forwarded-Host` | `my-app-123456.3.azure.databricksapps.com` | Original hostname | Standard proxy header |
| `X-Real-Ip` | `203.0.113.42` | Client IP (may differ from X-Forwarded-For in multi-hop) | Standard proxy header |

### X-Forwarded-Access-Token — what it is and isn't

| Property | Value |
|---|---|
| **Format** | JWT (`eyJ...`) — three base64url segments: `header.payload.signature` |
| **Issuer** | The Databricks Apps proxy (not the user's original OAuth provider) |
| **`sub` claim** | The app's **service principal UUID** — NOT the user |
| **Scopes** | Minimal OIDC: `offline_access email iam.current-user:read openid iam.access-control:read profile` |
| **Usable for** | Genie API, Agent Bricks / Model Serving (server-side scope validation) |
| **NOT usable for** | Statement Execution API (`sql` scope not present), direct UC queries |

Adding `sql` to the OAuth integration's `user_authorized_scopes` does NOT fix this — the platform issues a minimal OIDC identity token regardless of the integration configuration.

---

## Single-proxy path — browser to one app

The simple case: a user opens your app in a browser.

```
Step 1: User navigates to https://my-app-<workspace-id>.azuredatabricksapps.com
        Browser sends: session cookie (from prior OAuth login)

Step 2: Databricks Apps Proxy (automatic)
        +-- Validates session cookie against workspace OIDC
        +-- STRIPS the cookie / Authorization header
        +-- INJECTS:
        |     X-Forwarded-Email: alice@example.com
        |     X-Forwarded-User: 8362910284@1516413757355523
        |     X-Forwarded-Preferred-Username: Alice Example
        |     X-Forwarded-Access-Token: eyJ... (SP-scoped OIDC JWT)
        |     X-Forwarded-Groups: group_a,group_b
        |     X-Databricks-Org-Id: 1516413757355523
        +-- Forwards to app process on port 8000

Step 3: Your app receives the request
        +-- Reads X-Forwarded-Access-Token for OBO API calls (Genie, Agent Bricks)
        +-- Reads X-Forwarded-Email for identity display / audit
        +-- Uses WorkspaceClient() (no args) for M2M operations
```

**Headers at each hop:**

| Hop | Authorization | X-Forwarded-Email | X-Forwarded-Access-Token |
|---|---|---|---|
| Browser --> Proxy | Session cookie | (not set) | (not set) |
| Proxy --> your app | (stripped) | `alice@example.com` | `eyJ...` (SP JWT) |

---

## Two-proxy path — app calls another app

When one Databricks App calls another (e.g., Streamlit calls a custom MCP server), both apps have their own proxy. This creates the **two-proxy problem**.

```
+--------------------------------------------------------------+
|  USER BROWSER                                                |
|  Cookie: _databricks_session=abc123                          |
+---------------------------+----------------------------------+
                            |
                            v
+--------------------------------------------------------------+
|  PROXY 1 -- for the main app                                 |
|                                                              |
|  Validates: session cookie                                   |
|  Strips:   Cookie / Authorization                            |
|  Injects:  X-Forwarded-Email: alice@example.com              |
|            X-Forwarded-Access-Token: TOKEN_A (SP1 JWT)       |
|                                                              |
|  app.yaml: authorization: (default = enabled)                |
|  --> Proxy performs full authentication                       |
+---------------------------+----------------------------------+
                            |
                            v
+--------------------------------------------------------------+
|  MAIN APP CODE (e.g., Streamlit)                             |
|                                                              |
|  Reads: X-Forwarded-Access-Token --> user_token (TOKEN_A)   |
|                                                              |
|  Calls downstream app:                                       |
|    POST https://downstream-app-<ws-id>.azuredatabricksapps.com/endpoint
|    Headers:                                                  |
|      Authorization: Bearer {TOKEN_A}                         |
|      Content-Type: application/json                          |
+---------------------------+----------------------------------+
                            |
                            v
+--------------------------------------------------------------+
|  PROXY 2 -- for the downstream app                           |
|                                                              |
|  +--- With authorization: ENABLED (default) ---------------+|
|  | [X] STRIPS Authorization header from main app            ||
|  | [X] Replaces X-Forwarded-Access-Token with TOKEN_B       ||
|  |     (TOKEN_B.sub = downstream app's SP UUID)             ||
|  | [OK] Sets X-Forwarded-Email from its own validation      ||
|  | --> User's original Bearer token is LOST                  ||
|  +----------------------------------------------------------+|
|                                                              |
|  +--- With authorization: DISABLED -----------------------+ |
|  | [OK] Does NOT strip/replace the Authorization header    | |
|  | [OK] Passes through X-Forwarded-Email from upstream     | |
|  | [OK] Passes through all other headers unchanged         | |
|  | [X]  Does NOT perform authentication itself             | |
|  | [X]  Does NOT inject its own X-Forwarded-* headers      | |
|  +----------------------------------------------------------+ |
+---------------------------+----------------------------------+
                            |
                            v
+--------------------------------------------------------------+
|  DOWNSTREAM APP CODE (e.g., FastMCP server)                  |
|                                                              |
|  Reads X-Forwarded-Email --> caller identity                 |
|  Uses WorkspaceClient() --> M2M for data operations          |
+--------------------------------------------------------------+
```

### Headers at each hop (auth disabled on downstream)

| Hop | Authorization | X-Forwarded-Email | X-Forwarded-Access-Token |
|---|---|---|---|
| Browser --> Proxy 1 | Cookie | (not set) | (not set) |
| Proxy 1 --> main app | (stripped) | `alice@example.com` | `eyJ...TOKEN_A` |
| Main app --> Proxy 2 | `Bearer TOKEN_A` | (passes through from request context) | (not explicitly sent) |
| Proxy 2 --> downstream app | `Bearer TOKEN_A` (passthrough) | `alice@example.com` (passthrough) | (passthrough if present) |

### Headers at each hop (auth enabled on downstream — the problem)

| Hop | Authorization | X-Forwarded-Email | X-Forwarded-Access-Token |
|---|---|---|---|
| Browser --> Proxy 1 | Cookie | (not set) | (not set) |
| Proxy 1 --> main app | (stripped) | `alice@example.com` | `eyJ...TOKEN_A` |
| Main app --> Proxy 2 | `Bearer TOKEN_A` | (in request context) | (not sent) |
| Proxy 2 --> downstream app | **(stripped, replaced with SP2 token)** | `alice@example.com` (re-validated) | **`eyJ...TOKEN_B` (SP2 JWT)** |

TOKEN_B's `sub` is the downstream app's SP UUID. Using `WorkspaceClient(token=TOKEN_B)` → `current_user.me()` returns the SP identity, not the user.

---

## `authorization: disabled` — what it does

This setting in `app.yaml` controls whether the Databricks Apps proxy performs authentication.

```yaml
# app.yaml
authorization: disabled
```

| Behavior | auth: enabled (default) | auth: disabled |
|---|---|---|
| Proxy validates incoming token/cookie | Yes | **No** |
| Proxy strips Authorization header | Yes — replaces with SP token | **No** — passes through unchanged |
| Proxy injects X-Forwarded-Email | Yes — from its own validation | **No** — passes through whatever is in the request |
| Proxy injects X-Forwarded-Access-Token | Yes — SP-scoped OIDC JWT | **No** — passes through |
| Unauthenticated requests reach your app | No — proxy returns 401/302 | **Yes** — proxy is a passthrough |

### When to use it

| Scenario | auth: disabled | auth: enabled |
|---|---|---|
| **App-to-app calls** (main app calls downstream app) | Use on the downstream app — preserves the upstream token and identity headers | Proxy 2 strips the token and replaces identity |
| **Browser-facing apps** | No authentication = anyone can reach your app | Proxy handles OAuth SSO |
| **External MCP clients** (Claude Code, Cursor) | No X-Forwarded-Email injection (no upstream proxy) | Proxy validates OAuth and injects identity |

**Key insight:** `authorization: disabled` makes the proxy a passthrough. This is useful when identity headers were already set by an upstream proxy (app-to-app). It is harmful when there is no upstream proxy (browser or external client).

---

## External client path — Claude Code, Cursor, MCP Inspector

When an external client connects directly to a Databricks App (typically a custom MCP server), there is only one proxy and no upstream app.

```
External Client (e.g., Claude Code)
    |
    | stdio subprocess
    v
mcp-remote (npx)
    |
    | HTTPS POST with Authorization: Bearer {user_oauth_token}
    | (obtained via OAuth PKCE flow -- mcp-remote handles this)
    v
Proxy -- for the Databricks App
    |
    v
Your app (FastMCP server, port 8000)
```

| Client path | Needs auth: disabled | Needs auth: enabled |
|---|---|---|
| App-to-app (upstream app calls this one) | Preserves upstream identity | Strips upstream token |
| External client (Claude Code, Cursor) | No X-Forwarded-Email injected | Proxy validates and injects identity |
| Browser direct | No authentication | OAuth SSO |

---

## The deployment split problem

**You cannot serve both app-to-app and external-client paths with one deployment and one `authorization` setting.**

### Solution 1: Two deployments (simplest)

Deploy the same code twice with different app names:

- One with `authorization: disabled` for app-to-app calls
- One with `authorization: enabled` (default) for external clients and browsers
- Same SP grants apply to both (different SPs — grant both)

### Solution 2: Single deployment with token fallback

Keep `authorization: disabled`. Modify middleware to detect when `X-Forwarded-Email` is empty and fall back to parsing the Bearer JWT from the Authorization header.

```python
import base64, json

class ExtractTokenMiddleware:
    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = {k.lower(): v for k, v in scope.get("headers", [])}
            caller_email = headers.get(b"x-forwarded-email", b"").decode("utf-8")

            # Fallback: parse Bearer JWT when no proxy set X-Forwarded-Email
            if not caller_email:
                auth = headers.get(b"authorization", b"").decode("utf-8")
                if auth.startswith("Bearer eyJ"):
                    try:
                        payload = auth.split(" ")[1].split(".")[1]
                        payload += "=" * (-len(payload) % 4)  # pad base64
                        claims = json.loads(base64.urlsafe_b64decode(payload))
                        caller_email = claims.get("email", claims.get("sub", ""))
                    except Exception:
                        pass

            _request_caller.set(caller_email)
            # ... rest of middleware
```

Trade-off: you take on token validation responsibility.

---

## Design decisions

### Why X-Forwarded-Email over token parsing

| Approach | Pros | Cons |
|---|---|---|
| **X-Forwarded-Email** | Set by infrastructure; unforgeable when proxy enabled; no token parsing; survives token format changes | Requires proxy to set it (fails when auth disabled + no upstream proxy) |
| **Parse Bearer JWT** | Works without proxy; self-contained | Token format is platform-internal; `sub` may be SP UUID not email; requires JWT decode; token may become opaque in future |
| **`current_user.me()` API call** | Authoritative; works with any valid token | Extra API call per request; adds latency; requires `iam.current-user:read` scope |

### Why M2M for SQL instead of OBO token

The `X-Forwarded-Access-Token` is a minimal OIDC identity token without the `sql` scope. The pattern is: **identity from the proxy header, authorization from the app SP**. Read `X-Forwarded-Email` to know who is calling, then use `WorkspaceClient()` (app SP) to execute SQL with an explicit `WHERE` clause matching the caller. This produces the same access control as a UC row filter without requiring `sql` scope on the user's token.

### Why pure ASGI middleware (not BaseHTTPMiddleware)

Starlette's `BaseHTTPMiddleware` runs `call_next()` in a separate `asyncio.Task`. Python `ContextVar` values do not propagate across task boundaries. If you set a `ContextVar` before `call_next()`, the downstream route handler will not see the value. Use pure ASGI middleware that calls `self.app(scope, receive, send)` directly.

```python
# BROKEN -- ContextVar lost across task boundary
class BadMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        _request_caller.set("alice@example.com")
        response = await call_next(request)  # new task -- ContextVar gone
        return response

# CORRECT -- ContextVar preserved in same task
class GoodMiddleware:
    def __init__(self, app): self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            _request_caller.set("alice@example.com")
            await self.app(scope, receive, send)  # same task
```

---

## Gotchas

| Issue | Detail |
|---|---|
| **`ModelServingUserCredentials()` doesn't work in Apps** | It reads Model Serving's internal request context, which doesn't exist in Apps. Silently falls back to M2M — returns SP identity, not user. Use `X-Forwarded-Email` instead. |
| **`authorization: disabled` means no auth at all** | The proxy becomes a pure passthrough. Unauthenticated requests reach your app. Only use on downstream apps called by other apps, never on browser-facing apps. |
| **Two different SPs for two apps** | Each `databricks apps create` generates a new SP. Grants on the main app's SP do not carry over to the downstream app's SP. Grant both separately. |
| **X-Forwarded-Email empty = no upstream proxy** | If your middleware sees an empty `X-Forwarded-Email`, either auth is disabled and no upstream proxy set the header, or the request is unauthenticated. |
| **mcp-remote + auth disabled = OBO broken** | External clients using `mcp-remote` send a Bearer token but no `X-Forwarded-Email`. With auth disabled, the proxy doesn't validate the token or inject identity headers. OBO tools will fail. |
| **Token refresh doesn't pick up new scopes** | Adding scopes to an OAuth integration doesn't affect existing refresh tokens. A full app delete + recreate is required to force new authorization code flows. |

---

## Related

- [Authentication overview](authentication.md) — Identity patterns across Databricks Apps
- [U2M OBO from external apps](u2m-external-obo.md) — External SPA + Databricks OAuth PKCE
- [Auth playbook](auth-playbook.md) — Choosing the right auth pattern
- [AppKit auth patterns](appkit-auth-patterns.md) — SDK helpers for proxy header extraction
