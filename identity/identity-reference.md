# Identity and Authentication Reference

> **Purpose**: Canonical reference for authentication patterns, token flows, identity models, and OAuth scopes across all Databricks AI products. Consolidates content from multiple docs into a single source of truth.
>
> **Audience**: Field Engineers, Solution Architects, and Security Reviewers building or evaluating AI applications on Databricks.
>
> **Last updated**: 2026-03-12

---

## Table of Contents

1. [Three Authentication Patterns](#1-three-authentication-patterns)
2. [Token Flows and the Two-Proxy Problem](#2-token-flows-and-the-two-proxy-problem)
3. [Identity Models per Service](#3-identity-models-per-service)
4. [OAuth Scope Reference](#4-oauth-scope-reference)
5. [Identity Fragmentation and Known Gaps](#5-identity-fragmentation-and-known-gaps)
6. [Quick Decision Guide](#6-quick-decision-guide)

---

## 1. Three Authentication Patterns

Every Databricks AI application uses one or more of these three patterns. They are universal across Agent Bricks, Databricks Apps, Genie, and custom MCP servers.

### Pattern 1: Automatic Passthrough (M2M)

The platform issues short-lived credentials for a dedicated service principal tied to declared resources. The SP has least-privilege access scoped to what was declared at agent log time.

- **Token type**: Short-lived SP token (OAuth client credentials)
- **Identity in audit**: Service Principal UUID
- **UC enforcement**: SP-level permissions
- **Use cases**: Batch jobs, automation, background tasks, shared-resource queries
- **Docs**: [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m.html), [Automatic Passthrough](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#automatic-authentication-passthrough)

### Pattern 2: On-Behalf-Of User (OBO)

The agent or app runs as the end user. Unity Catalog enforces row filters, column masks, and ABAC policies per user. The user's identity is preserved in audit logs.

- **Token type**: User token (downscoped per request)
- **Identity in audit**: Human email
- **UC enforcement**: Per-user row filters, column masks, ABAC
- **Use cases**: User-facing apps, per-user data access, Genie queries, agent endpoints
- **Key requirement**: Initialize user-authenticated clients inside `predict()` at request time; declare required scopes
- **Docs**: [OBO Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#on-behalf-of-user-authentication), [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m.html)

### Pattern 3: Manual Credentials

External API keys or SP OAuth credentials stored in Databricks Secrets. Used for services outside the Databricks platform.

- **Token type**: External API key or SP OAuth token
- **Identity in audit**: Depends on external service
- **UC enforcement**: None (external to Databricks)
- **Use cases**: External LLM APIs, external MCP servers, third-party SaaS
- **Docs**: [Manual Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#manual-authentication), [Secrets](https://docs.databricks.com/aws/en/security/secrets/)

### When to Use Each

| Question | Answer |
|---|---|
| User should only see their data? | OBO (Pattern 2) |
| Everyone sees the same data? | M2M (Pattern 1) |
| Need user identity in platform audit? | OBO where possible; app-level audit for M2M paths |
| External API or third-party service? | Manual Credentials (Pattern 3) |
| Background/batch processing? | M2M (Pattern 1) |

---

## 2. Token Flows and the Two-Proxy Problem

### Databricks Apps Token Architecture

When a Databricks App serves a browser user, the platform proxy injects identity headers into every request:

```
User browser
    |  HTTPS + session cookie
    v
[App Envoy Proxy]
    |  injects X-Forwarded-Access-Token (OIDC identity JWT)
    |  injects X-Forwarded-Email (authenticated user email)
    v
app.py (your application code)
```

**Proxy-injected headers** (cannot be forged by calling apps when `user_authorization_enabled: true`):

| Header | Content | Trust level |
|---|---|---|
| `X-Forwarded-Email` | `alice@example.com` | High -- use for identity |
| `X-Forwarded-User` | `{user_id}@{workspace_id}` | High |
| `X-Forwarded-Preferred-Username` | `Alice Example` (display name) | High |
| `X-Forwarded-Access-Token` | Minimal OIDC JWT (iam.* scopes only) | Medium -- identity only, not for all API calls |
| `X-Databricks-Org-Id` | Workspace ID | Informational |

### The Two-Proxy Problem

When a Streamlit app (App A) calls a custom MCP server (App B) and both are Databricks Apps, each has its own proxy:

```
User browser
    |  HTTPS + session cookie
    v
[App A Envoy Proxy]              <-- Proxy 1
    |  injects X-Forwarded-Access-Token (Token A = user OBO token)
    |  injects X-Forwarded-Email (user email)
    v
app.py (Streamlit)
    |  Authorization: Bearer {Token A}   <-- app forwards Token A
    v
[App B Envoy Proxy]              <-- Proxy 2
    |  STRIPS the incoming Authorization header
    |  injects X-Forwarded-Access-Token (Token B = App B SP token)
    |  injects X-Forwarded-Email (user email, derived from Token A)
    v
server/main.py (FastMCP)
    |  Token B sub = MCP SP UUID (NOT the user)
    |  X-Forwarded-Email = correct user email
```

**The problem**: Proxy 2 substitutes its own SP token for the user's token. The MCP server code never sees the user's OBO token.

**The solution**: Use `X-Forwarded-Email` (set by the proxy from the validated incoming token, cannot be forged) for user identity. Use `WorkspaceClient()` (M2M, no args) for SQL queries, with explicit `WHERE user_email = '{caller}'` filter in each query.

### Token A vs Token B

| Token | Issued by | Identity | Usable for |
|---|---|---|---|
| Token A (main app) | Proxy 1 | User (OIDC identity JWT) | Genie API, Agent Bricks, Model Serving (server-side scope validation) |
| Token B (MCP app) | Proxy 2 | App B SP UUID | Same minimal OIDC scopes as Token A; `sub` = SP, not user |

**Key insight**: Using `current_user.me()` with Token B returns the SP identity, not the user.

### The Three-Proxy Path (UC External MCP)

When the MCP server is registered as a UC HTTP Connection, there is a third proxy:

```
User browser
    --> [App Proxy]              checks session, injects Token A + email
    --> app.py                   forwards Token A as Bearer
    --> [UC External MCP Proxy]  checks unity-catalog scope + USE CONNECTION
    --> [MCP App Proxy]          strips Bearer, injects Token B + email
    --> server/main.py           receives Token B (SP) + email (user)
```

The UC proxy adds a governance layer: it validates the `unity-catalog` scope on the calling token and checks `USE CONNECTION` privilege on the caller's identity. Revoking `USE CONNECTION` immediately blocks access.

### What NOT to Use in the MCP Server

- `ModelServingUserCredentials()` -- silently falls back to M2M in Databricks Apps context
- `WorkspaceClient(host=host, token=user_token)` -- SDK raises conflict error if `DATABRICKS_CLIENT_ID/SECRET` env vars are also set
- The `X-Forwarded-Access-Token` for SQL -- the token lacks the `sql` scope claim (unless configured via UI "User authorization")

---

## 3. Identity Models per Service

Each Databricks AI service resolves identity differently. This table shows what identity is visible in `system.access.audit` for each service and auth pattern combination.

| Service | Auth Pattern | Identity in `system.access.audit` | Human Visible? |
|---|---|---|---|
| Genie Space | OBO | Human email | Yes |
| Agent Bricks endpoint | Automatic passthrough | SP UUID | No |
| Agent Bricks endpoint | OBO | Human email | Yes |
| SQL Warehouse (via M2M) | M2M | SP UUID | No |
| SQL Warehouse (via OBO + UI scopes) | OBO | Human email | Yes |
| Vector Search | Automatic passthrough | SP UUID | No |
| UC Functions | Caller identity | Depends on calling context | Depends |
| Custom MCP (direct) | Two-proxy M2M | SP UUID (App B SP) | No |
| Custom MCP (UC proxy) | Three-proxy | Calling identity at UC layer | Partially |
| External APIs | Manual credentials | External service logs | N/A |

**The identity fragmentation problem**: In a single user interaction, `system.access.audit` may show the human email for Genie queries but the SP UUID for M2M SQL queries. There is no platform-built join between these records.

---

## 4. OAuth Scope Reference

> **Verified on Azure Databricks, March 2026.** Add ALL scopes upfront -- missing scopes cause cryptic errors discovered per-feature, not per-project. Extra scopes are harmless.

### Scope Map

| Scope | Required for | Notes |
|---|---|---|
| `dashboards.genie` | Genie Conversation API (all clouds) | Must be in `user_authorized_scopes` |
| `genie` | Genie Conversation API on **Azure** | Undocumented Azure-specific requirement -- UI does not show this scope |
| `model-serving` | Agent Bricks / Model Serving OBO | |
| `sql` | Statement Execution API | Adding via CLI does NOT embed it in the JWT -- use UI "User authorization" or M2M for SQL |
| `unity-catalog` | External MCP proxy `/api/2.0/mcp/external/...` | Undocumented -- proxy checks USE CONNECTION privilege; missing = 403 |
| `all-apis` | General Databricks REST APIs | Catch-all |
| `offline_access`, `email`, `openid`, `profile`, `iam.*` | OIDC identity baseline | Always required |

### CLI Patch Command (Run Once After Any App Create or Delete+Recreate)

```bash
databricks account custom-app-integration update '<integration-id>' \
  --profile <account-profile> \
  --json '{
    "scopes": ["offline_access","email","iam.current-user:read",
               "openid","dashboards.genie","genie","iam.access-control:read",
               "profile","model-serving","sql","all-apis","unity-catalog"],
    "user_authorized_scopes": ["dashboards.genie","genie","model-serving",
                                "sql","all-apis","unity-catalog"]
  }'
```

### Two Configuration Paths for Scopes

| Mechanism | How | Result |
|---|---|---|
| **CLI** `custom-app-integration update` | Sets `user_authorized_scopes` on OAuth integration | Sets scopes in config but does NOT populate `effective_user_api_scopes`. Proxy still issues minimal OIDC identity token. |
| **UI** User Authorization (Preview) | Edit App -> Configure -> User Authorization -> Add Scope | Sets both `user_authorized_scopes` AND `effective_user_api_scopes`. Produces real OBO JWT with service scopes embedded. |

**Always use the UI** for adding scopes when you need them in the token's `scope` claim. The CLI approach alone does not result in service scopes appearing in the `X-Forwarded-Access-Token`.

### UI Scope Names

| UI scope name | What it enables |
|---|---|
| `sql` | OBO SQL via Statement Execution API -- `current_user()` = human email |
| `dashboards.genie` | Genie space access |
| `serving.serving-endpoints` | Model Serving / Agent Bricks OBO (maps to CLI scope `model-serving`) |
| `catalog.connections` | UC HTTP Connection access |
| `catalog.catalogs:read` | Read-only UC catalog access |
| `files.files` | File and directory access |

### Scope Behavior: Why Some APIs Work and Some Don't

The `X-Forwarded-Access-Token` is an OIDC identity token, not a full API token:

| API | Scope check | Works with identity token? |
|---|---|---|
| SCIM `Me` endpoint | Server-side, `iam.current-user:read` in token | Yes |
| Genie Conversation API | Server-side only | Yes |
| Agent Bricks / Model Serving | Server-side only | Yes |
| Statement Execution API | JWT `scope` claim must contain `sql` | No (CLI config) / Yes (UI config) |
| External MCP proxy | JWT `scope` claim must contain `unity-catalog` | Yes if in `user_authorized_scopes` |

### OAuth Integration Reset

Adding a scope to `user_authorized_scopes` does NOT affect existing refresh tokens. When the Apps proxy refreshes an access token, the new access token inherits the original scopes from the authorization code grant -- not the current integration configuration. Opening the app in incognito does not help if the workspace SSO session is still valid.

**The only fix**: Delete and recreate the app (creates a new OAuth integration), then immediately patch the new integration with the full scope set.

---

## 5. Identity Fragmentation and Known Gaps

### The Problem

Databricks AI applications use multiple services, each with a different identity model. In a single user interaction:

1. **Genie query**: `system.access.audit` records the human email (OBO)
2. **M2M SQL query**: `system.access.audit` records the SP UUID (M2M)
3. **MLflow trace**: Records the human email in trace tags (app-level)
4. **Custom MCP tool**: Logs caller via `X-Forwarded-Email` (app-level)

The human who triggered the M2M SQL query is invisible in the data-plane audit log.

### Known Gaps

| Gap | Description | Impact | Workaround |
|---|---|---|---|
| **M2M audit loses human identity** | When an app uses M2M for SQL, `system.access.audit` records the SP UUID, not the human | Cannot determine which user triggered which query | Use OBO SQL (UI "User authorization" with `sql` scope) where possible; add app-level audit for M2M paths |
| **No MLflow-to-audit join** | MLflow traces and `system.access.audit` are separate systems | Cannot trace from agent invocation to data access | Generate a `trace_id` at the agent entry point, pass through tool calls, log in both systems, join manually |
| **Scope overexposure** | OAuth integrations default to `all-apis` | User token has access to every workspace service | Declare minimum required scopes explicitly |
| **`is_member()` under OBO** | In some OBO contexts (Genie), `is_member()` evaluates the SQL execution identity, not the calling user | Row filters using `is_member()` return the same result for all users | Use `current_user()` + allowlist table lookup instead of `is_member()` |

### Proposed Two-Layer Audit Architecture

```
Application Plane (build it yourself):
  MLflow traces --> Delta table --> has human email, trace_id, tool calls

Data Plane (platform-provided):
  system.access.audit --> has executing identity (human or SP), SQL queries

Correlation:
  JOIN on shared trace_id or timestamp window
  Gap: No platform-built join exists
```

For details on building the app-level audit layer, see [Observability and Audit](observability-and-audit.md).

---

## 6. Quick Decision Guide

### Choosing an Auth Pattern

```
Is the user accessing their own data?
  |
  +-- YES --> Use OBO (Pattern 2)
  |            - Genie queries: OBO by default
  |            - SQL: Add sql scope via UI
  |            - Agent Bricks: Enable OBO in endpoint config
  |
  +-- NO --> Is this a shared/system resource?
              |
              +-- YES --> Use M2M (Pattern 1)
              |            - Vector Search, knowledge base
              |            - Background jobs, CRM sync
              |
              +-- NO --> Is this an external service?
                          |
                          +-- YES --> Use Manual Credentials (Pattern 3)
                          |
                          +-- NO --> Re-evaluate your architecture
```

### Choosing SQL Authentication

```
Do you need per-user row filter enforcement at the SQL layer?
  |
  +-- YES --> Use OBO SQL
  |            - Configure sql scope via Account Console UI
  |            - Use httpx/requests with X-Forwarded-Access-Token
  |            - current_user() = human email in audit
  |
  +-- NO --> Use M2M SQL
              - WorkspaceClient() with no args
              - Add WHERE clause filtering on X-Forwarded-Email
              - SP UUID in audit (add app-level logging for human identity)
```

---

## 7. Complete Service Identity Map (16 Services)

This table covers every Databricks AI service and how identity resolves in each. The three identity models are:

| Model | Who executes | User identity source | `current_user()` returns | UC audit shows |
|---|---|---|---|---|
| **True OBO** | User's token | OAuth token | User email | User email |
| **Proxy identity + M2M** | App SP | `X-Forwarded-Email` (injected by proxy) | SP UUID | SP UUID |
| **Pure M2M** | App SP | Not involved | SP UUID | SP UUID |

### Per-service breakdown

| # | Service | Identity model | User identity source | `current_user()` | UC audit identity |
|---|---|---|---|---|---|
| 1 | **Genie** (Conversation API) | True OBO | Token `sub` claim | User email | User |
| 2 | **AI/BI Dashboard** (run-as-viewer) | True OBO | Dashboard viewer session | Viewer email | Viewer |
| 3 | **AI/BI Dashboard** (run-as-owner) | Delegated | Dashboard owner | Owner email | Owner |
| 4 | **Agent Bricks / Model Serving** | True OBO | Token forwarded end-to-end | User email | User |
| 5 | **SQL Warehouse** (direct, user token) | True OBO | Token `sub` claim | User email | User |
| 6 | **SQL Warehouse** (direct, SP token) | Pure M2M | None | SP UUID | SP UUID |
| 7 | **Custom MCP** (Databricks Apps) | Proxy identity + M2M **OR** True OBO (with UI User Authorization + `sql` scope) | `X-Forwarded-Email` (M2M); Token `sub` (OBO) | SP UUID (M2M); User email (OBO SQL) | SP UUID (M2M); User email (OBO SQL) |
| 8 | **UC Functions** (via M2M SQL) | Pure M2M | None (or passed as function arg) | SP UUID | SP UUID |
| 9 | **UC Functions** (via Genie OBO) | True OBO | Token `sub` claim | User email | User |
| 10 | **Vector Search** | Pure M2M | None | N/A (no SQL) | SP UUID |
| 11 | **Foundation Model API** | Pure M2M or OBO | SP or user token | N/A | Caller identity |
| 12 | **SDP / Lakeflow Pipeline** (serverless) | Delegated | Pipeline config | Owner email | Owner |
| 13 | **External MCP** (shared bearer via UC HTTP) | M2M at proxy | Shared credential at external service | N/A | Caller at proxy |
| 14 | **External MCP** (per-user OAuth via UC HTTP) | OBO at proxy | Individual user at external service | N/A | User at proxy |
| 15 | **Custom MCP to Custom MCP** (chained) | Proxy identity + M2M | `X-Forwarded-Email` (passthrough) | SP UUID | SP UUID |
| 16 | **Lakebase** (online tables) | TBD -- not yet GA | Expected: same as Model Serving | TBD | TBD |

**Governance boundary for External MCP (#13, #14)**: `USE CONNECTION` grant controls who can invoke. The MCP server itself needs zero data permissions -- UC manages the credential lifecycle.

### Audit gap summary

| Identity model | UC audit captures human? | Application-plane audit required? |
|---|---|---|
| True OBO (#1, 2, 3, 4, 5, 9) | **Yes** -- automatic | Optional (enrichment) |
| Proxy identity + M2M (#7, 15) | **No** -- shows SP UUID. **Solvable** with UI User Authorization + `sql` scope for the OBO SQL path. | **Required** for M2M path; not required when using OBO SQL via UI User Auth |
| Pure M2M (#6, 8, 10, 11) | **No** -- shows SP UUID | **Required** if per-user attribution matters |
| Delegated (#3, 12) | **Yes** -- but shows owner, not end user | Depends on use case |
| External MCP (#13, 14) | N/A -- external service | **Required** -- Databricks audit shows proxy call, not external action |

---

## 8. Product Gaps -- Detailed Evidence

### GAP 1: M2M audit trail loses human identity -- SOLVABLE via OBO SQL

**Status**: Solvable. With UI User Authorization (Public Preview) + `sql` scope, Custom MCP apps can execute OBO SQL where `current_user()` returns the human email and UC audit records the human identity directly.

```sql
-- What UC audit shows for an M2M query:
SELECT event_time, user_identity.email, action_name, service_name
FROM system.access.audit
WHERE service_name = 'unityCatalog'
  AND event_time > current_timestamp() - INTERVAL 1 HOUR;

-- M2M path result:
-- user_identity.email = <sp-application-id>  (SP UUID, not human)

-- OBO SQL via UI User Auth result:
-- user_identity.email = user@example.com     (human email -- gap closed)
```

**Affected services (M2M path only)**: Custom MCP (#7 when not using OBO SQL), UC Functions via M2M (#8), Vector Search (#10), any M2M SQL path (#6).

### GAP 2: No platform-built join between MLflow traces and UC audit

`mlflow.traces` and `system.access.audit` are separate system tables with no foreign key relationship. The join requires matching on SP UUID + time window -- an approximation, not a precise correlation.

### GAP 3: `sql` scope in JWT -- RESOLVED (configuration issue)

Adding `sql` to `user_authorized_scopes` via CLI did not result in the `sql` claim appearing in the JWT. The resolution: configure `sql` scope via the Databricks Apps UI "User authorization" panel. The resulting `X-Forwarded-Access-Token` is a real OBO JWT with the `sql` scope claim. Track configured scopes via `effective_user_api_scopes` on the app object.

### GAP 4: `is_member()` broken in OBO contexts through Genie/Agent Bricks

`is_member()` in a row filter or column mask evaluates the SQL **execution identity** (Genie service, Agent Bricks runtime), not the OBO caller's workspace groups. Needs re-test under UI User Authorization where the SQL session identity is the actual user.

**Workaround**: Use `current_user()` + allowlist table lookup instead of `is_member()`.

### GAP 5: `unity-catalog` scope requirement for External MCP -- undocumented

Calling `/api/2.0/mcp/external/{connection_name}` without the `unity-catalog` scope returns `403: "Provided OAuth token does not have required scopes: unity-catalog"`. This scope is not mentioned in the External MCP documentation.

### GAP 6: Token scope refresh requires full app rebuild

Adding scopes to an existing OAuth integration does not propagate to existing refresh tokens. Users must re-authorize via a new authorization code flow. The only reliable method: delete and recreate the Databricks App (creates a new OAuth integration, new SP, new client_id). Every scope change is a destructive operation that requires re-granting the new SP's UC access.

### GAP 7: `authorization: disabled` cannot serve both app-to-app and external clients

App-to-app calls need auth disabled (to preserve upstream token). External clients need auth enabled (to trigger proxy identity injection). No single setting works for both.

### GAP 8: Connection owner has implicit `USE CONNECTION`

The owner of a UC HTTP connection has implicit `USE CONNECTION` permission. This permission does not appear in `SHOW GRANTS` for the owner -- making access audits incomplete if you only check explicit grants. When auditing who can access an External MCP server, check both explicit `USE CONNECTION` grants AND connection ownership.

### GAP 9: Lakebase data-plane query audit undocumented

Lakebase management audit is captured in `system.access.audit` under service `databaseInstances` (15 actions). What remains undocumented: whether data-plane Postgres SQL queries (SELECT/INSERT/UPDATE/DELETE) appear in `system.access.audit`, and if so, what identity is recorded.

---

## 9. Audit Decorator Pattern

The `@audited` decorator wraps any MCP tool with audit logging. Zero changes to tool logic required.

### Design goals

1. Every tool invocation records who (human) asked for what (tool + args) via which agent (SP)
2. Records are immutable (Delta table with append-only semantics + change data feed)
3. Joinable with `system.access.audit` via SP UUID + time window
4. Joinable with `mlflow.traces` via trace_id (when available)
5. Extensible -- new services add rows, not schema changes
6. Zero code changes to tool logic

### Audit table DDL

```sql
CREATE SCHEMA IF NOT EXISTS <catalog>.<schema>;

CREATE TABLE IF NOT EXISTS <catalog>.<schema>.tool_invocations (
  -- WHO triggered it (human identity from proxy)
  caller_email       STRING     NOT NULL   COMMENT 'X-Forwarded-Email -- proxy-verified user identity',
  caller_user_id     STRING                COMMENT 'X-Forwarded-User -- {user_id}@{workspace_id}',
  caller_display     STRING                COMMENT 'X-Forwarded-Preferred-Username -- display name',

  -- WHICH agent executed it (SP identity)
  app_sp_id          STRING     NOT NULL   COMMENT 'DATABRICKS_CLIENT_ID -- the SP that ran SQL',
  app_name           STRING     NOT NULL   COMMENT 'Application name for multi-app correlation',

  -- WHAT was done
  service_type       STRING     NOT NULL   COMMENT 'custom_mcp | uc_function | external_mcp | agent_bricks | genie',
  tool_name          STRING     NOT NULL   COMMENT 'Tool/function name invoked',
  tool_args_hash     STRING                COMMENT 'SHA-256 of canonical args JSON -- for dedup and correlation',
  tool_args_safe     STRING                COMMENT 'Sanitized JSON args (secrets/PII redacted)',
  result_status      STRING     NOT NULL   COMMENT 'success | error | denied | timeout',
  error_message      STRING                COMMENT 'Error detail if status != success',

  -- CORRELATION keys
  trace_id           STRING                COMMENT 'MLflow trace ID -- precise join to mlflow.traces',
  request_id         STRING     NOT NULL   COMMENT 'UUID per invocation -- unique across all apps',

  -- TIMING
  event_time         TIMESTAMP  NOT NULL   COMMENT 'Server-side UTC timestamp',
  duration_ms        LONG                  COMMENT 'Wall-clock execution time in milliseconds'
)
USING DELTA
COMMENT 'Application-plane audit log for MCP tool invocations. Joins with system.access.audit on app_sp_id + event_time window.'
TBLPROPERTIES (
  'delta.enableChangeDataFeed' = 'true',
  'delta.logRetentionDuration' = 'interval 365 days',
  'delta.deletedFileRetentionDuration' = 'interval 365 days'
);

-- Grant the MCP app SP write access
GRANT MODIFY ON TABLE <catalog>.<schema>.tool_invocations TO `<sp-application-id>`;
GRANT USE CATALOG ON CATALOG <catalog> TO `<sp-application-id>`;
GRANT USE SCHEMA ON SCHEMA <catalog>.<schema> TO `<sp-application-id>`;
```

### Decorator implementation

```python
"""audit.py -- Drop-in audit decorator for MCP tools."""
import hashlib, json, os, time
from datetime import datetime, timezone
from functools import wraps

APP_SP_ID = os.environ.get("DATABRICKS_CLIENT_ID", "unknown")
APP_NAME = os.environ.get("APP_NAME", "my-mcp-server")
AUDIT_CATALOG = "<catalog>"
AUDIT_SCHEMA = "<schema>"

_SENSITIVE_KEYS = frozenset({"password", "secret", "token", "api_key", "credential"})

def _sanitize_args(args: dict) -> str:
    safe = {}
    for k, v in args.items():
        if k.lower() in _SENSITIVE_KEYS:
            safe[k] = "***REDACTED***"
        elif isinstance(v, str) and len(v) > 500:
            safe[k] = v[:500] + "...[truncated]"
        else:
            safe[k] = v
    return json.dumps(safe, default=str, sort_keys=True)

def _args_hash(args: dict) -> str:
    canonical = json.dumps(args, default=str, sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]

def audited(service_type: str = "custom_mcp"):
    """Decorator that wraps any MCP tool with audit logging.

    Usage:
        @mcp.tool()
        @audited()
        def my_tool(arg1: str) -> dict:
            ...

    For UC Functions or other services:
        @audited(service_type="uc_function")
    """
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            import uuid as _uuid
            # _caller_email() and _request_headers should be implemented
            # per your framework (e.g., reading from ContextVar set by middleware)
            caller = _caller_email()
            headers = _request_headers.get({})
            caller_user_id = headers.get("x-forwarded-user", "")
            caller_display = headers.get("x-forwarded-preferred-username", "")
            request_id = str(_uuid.uuid4())

            start = time.monotonic()
            try:
                result = func(*args, **kwargs)
                duration_ms = int((time.monotonic() - start) * 1000)
                status = "error" if isinstance(result, dict) and "error" in result else "success"
                error_msg = result.get("error") if status == "error" else None
                _write_audit_record(
                    caller, caller_user_id, caller_display,
                    service_type, func.__name__, kwargs,
                    status, error_msg, None, request_id, duration_ms,
                )
                return result
            except Exception as e:
                duration_ms = int((time.monotonic() - start) * 1000)
                _write_audit_record(
                    caller, caller_user_id, caller_display,
                    service_type, func.__name__, kwargs,
                    "error", str(e), None, request_id, duration_ms,
                )
                raise
        return wrapper
    return decorator
```

### Applying to tools (one-line change per tool)

```python
@mcp.tool()
@audited()
def get_deal_approval_status(opp_id: str) -> dict:
    # ... existing logic unchanged ...

@mcp.tool()
@audited(service_type="uc_function")
def call_uc_function(func_name: str, args: dict) -> dict:
    # ... existing logic unchanged ...

@mcp.tool()
@audited(service_type="external_mcp")
def call_external_mcp(connection_name: str, tool: str, args: dict) -> dict:
    # ... existing logic unchanged ...
```

---

## 10. Chain-of-Custody Query

This query joins the application-plane audit table with the data-plane `system.access.audit` to produce a full chain of custody: human -> tool -> SQL -> data.

```sql
WITH app_events AS (
  SELECT
    request_id,
    caller_email,
    caller_display,
    app_sp_id,
    app_name,
    service_type,
    tool_name,
    tool_args_safe,
    result_status,
    error_message,
    trace_id,
    event_time,
    duration_ms,
    event_time - INTERVAL 2 SECONDS  AS window_start,
    event_time + INTERVAL 30 SECONDS AS window_end
  FROM <catalog>.<schema>.tool_invocations
  WHERE event_time > current_timestamp() - INTERVAL 24 HOURS
),
uc_events AS (
  SELECT
    event_time      AS uc_event_time,
    user_identity.email AS uc_executor,
    action_name     AS uc_action,
    request_params  AS uc_params,
    service_name    AS uc_service,
    response.status_code AS uc_status
  FROM system.access.audit
  WHERE event_time > current_timestamp() - INTERVAL 24 HOURS
    AND service_name IN ('unityCatalog', 'sqlStatements', 'databricksSql')
)
SELECT
  a.caller_email                     AS human,
  a.caller_display                   AS human_name,
  a.tool_name                        AS tool,
  a.tool_args_safe                   AS args,
  a.result_status                    AS tool_result,
  a.duration_ms                      AS tool_duration_ms,
  u.uc_action                        AS uc_operation,
  u.uc_executor                      AS uc_identity,
  u.uc_status                        AS uc_status,
  a.event_time                       AS tool_time,
  u.uc_event_time                    AS uc_time,
  a.app_sp_id                        AS agent_sp,
  a.trace_id
FROM app_events a
LEFT JOIN uc_events u
  ON u.uc_executor = a.app_sp_id
  AND u.uc_event_time BETWEEN a.window_start AND a.window_end
ORDER BY a.event_time DESC;
```

**Result example:**

```
human              | tool                       | uc_operation   | uc_identity       | tool_time           | uc_time
alice@acme.com     | get_deal_approval_status   | commandSubmit  | <sp-application-id> | 2026-03-10 14:32:01 | 2026-03-10 14:32:02
alice@acme.com     | submit_deal_for_approval   | commandSubmit  | <sp-application-id> | 2026-03-10 14:33:15 | 2026-03-10 14:33:16
bob@acme.com       | get_crm_sync_status        | commandSubmit  | <sp-application-id> | 2026-03-10 14:35:22 | 2026-03-10 14:35:23
```

UC only knows `<sp-application-id>` ran queries. Your audit table proves Alice and Bob triggered them.

---

## 11. Confused Deputy Prevention -- SP Isolation

### The problem

A **confused deputy** attack occurs when a trusted entity (the app SP) is tricked into using its authority on behalf of an unauthorized caller. In Databricks Apps context, a single SP shared across a read-only dashboard AND a write-capable MCP server means the dashboard's SP credentials can be exploited to write data.

### The principle: One SP per capability boundary

Every deployed agent is a Service Principal. One SP per capability boundary -- not one SP per application. An agent that does read-only analysis and an agent that submits approvals must have different SPs.

### SP isolation matrix (example)

| App / Component | SP | Read capabilities | Write capabilities | Why separate |
|---|---|---|---|---|
| **Frontend app** | SP-A | Genie (OBO), VS indexes, UC Functions, FM API | None | Frontend should never have direct write access |
| **Custom MCP server** | SP-B | Data tables | Approval table (INSERT only) | MCP tools need MODIFY; frontend does not |
| **External client MCP** | SP-C | Same read tables as SP-B | Same write tables as SP-B | Independent lifecycle, different auth settings |
| **Supervisor agent** | SP-D (auto-managed) | Sub-agents inherit user token (OBO) | Through sub-agent tools only | Platform-managed SP |

### What SP isolation buys you

| Scenario | Single shared SP | Isolated SPs |
|---|---|---|
| Frontend app compromised | Attacker has MODIFY on approval table | SP-A has no MODIFY -- attack surface limited to read-only |
| MCP tool injection | Same SP has access to all tables across all apps | SP-B only has grants on specific tables; blast radius contained |
| Credential rotation | Must rotate for all apps simultaneously | Rotate per-app; others unaffected |
| Audit investigation | All M2M queries show same SP UUID | Different SP UUIDs in `system.access.audit` -- immediate attribution to app |

### Anti-patterns to avoid

| Anti-pattern | Why it's dangerous | Correct approach |
|---|---|---|
| Sharing `DATABRICKS_CLIENT_ID/SECRET` across apps | One credential compromise = all apps compromised | Each `databricks apps create` auto-generates a unique SP |
| Granting `ALL PRIVILEGES` on a catalog to an SP | SP can do anything -- read, write, drop, grant | Grant only specific object-level permissions |
| Using same SP for read and write tools | A read-only tool vulnerability becomes a write exploit | Separate SPs per capability boundary |
| Adding the MCP SP to admin groups | SP bypasses all row filters and column masks | SP should only be in groups matching its declared capabilities |

---

## 12. Alert Views for Audit Monitoring

```sql
-- Alert: tool invocation by unknown caller (empty email = broken auth)
CREATE OR REPLACE VIEW <catalog>.<schema>.alert_missing_identity AS
SELECT * FROM <catalog>.<schema>.tool_invocations
WHERE caller_email = '' OR caller_email IS NULL;

-- Alert: high-frequency tool calls from single user (potential abuse)
CREATE OR REPLACE VIEW <catalog>.<schema>.alert_high_frequency AS
SELECT caller_email, tool_name, COUNT(*) AS call_count,
       MIN(event_time) AS first_call, MAX(event_time) AS last_call
FROM <catalog>.<schema>.tool_invocations
WHERE event_time > current_timestamp() - INTERVAL 1 HOUR
GROUP BY caller_email, tool_name
HAVING COUNT(*) > 50;

-- Alert: write operations
CREATE OR REPLACE VIEW <catalog>.<schema>.alert_write_ops AS
SELECT * FROM <catalog>.<schema>.tool_invocations
WHERE tool_name IN ('submit_deal_for_approval')
  AND result_status = 'success'
ORDER BY event_time DESC;

-- Alert: error rate spike
CREATE OR REPLACE VIEW <catalog>.<schema>.alert_error_rate AS
SELECT tool_name,
       COUNT(*) AS total,
       SUM(CASE WHEN result_status = 'error' THEN 1 ELSE 0 END) AS errors,
       ROUND(SUM(CASE WHEN result_status = 'error' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS error_pct
FROM <catalog>.<schema>.tool_invocations
WHERE event_time > current_timestamp() - INTERVAL 1 HOUR
GROUP BY tool_name
HAVING error_pct > 10;
```

---

## 13. System Tables -- Complete Inventory

### Access and audit

| Table | What it records | Identity field | Useful for |
|---|---|---|---|
| `system.access.audit` | All UC operations, SQL executions, API calls, app lifecycle | `user_identity.email` (executing identity) | Primary audit trail |
| `system.access.table_lineage` | Table-level data flow (source to target) | Source/target table metadata | Understanding data flow through pipelines and agents |
| `system.access.column_lineage` | Column-level data flow | `source_column_name`, `target_column_name` | PII propagation tracking |

### Governance metadata (information_schema)

| Table | What it records | Useful for |
|---|---|---|
| `system.information_schema.column_tags` | Column-level tags (including auto-classified PII) | ABAC policies, data classification audit |
| `system.information_schema.table_tags` | Table-level tags | Tag-based access control |
| `system.information_schema.column_masks` | Applied column mask functions | Verify masks are applied to sensitive columns |
| `system.information_schema.metastore_privileges` | Metastore admin grants | Privilege escalation detection |

### Compute and billing

| Table | What it records | Identity field | Useful for |
|---|---|---|---|
| `system.billing.usage` | DBU consumption and cost | `identity_metadata` | Cost attribution per user/SP/workspace |
| `system.compute.clusters` | Cluster creation and lifecycle events | `creator_user_name` | Cluster ownership, resource tracking |
| `system.lakeflow.job_run_timeline` | Job/pipeline execution history | `run_as` identity | Pipeline owner attribution |

### MLflow (application plane)

| Table | What it records | Useful for |
|---|---|---|
| `mlflow.traces` | Agent conversation traces with spans | Application-plane audit -- what the agent decided, what tools it called |

**Key limitation of `system.access.audit`**: Records the executing identity only. For M2M, this is the SP UUID -- not the human who triggered it. There is no `requested_by` or `on_behalf_of` field.

---

## Related Documents

- [Authorization Flows](authorization-flows.md) -- UC four-layer access control (workspace bindings, privileges, ABAC, row/column filtering)
- [OBO vs M2M Decision Matrix](obo-vs-m2m-decision-matrix.md) -- Detailed decision framework with audit implications
- [Observability and Audit](observability-and-audit.md) -- Two-layer audit model, app-plane and data-plane correlation
- [UC Policy Design Principles](../UC-POLICY-DESIGN-PRINCIPLES.md) -- `current_user()` vs `is_member()` in all execution contexts
