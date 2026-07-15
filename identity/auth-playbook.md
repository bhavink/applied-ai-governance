<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/overview.md, auth/obo-passthrough.md, auth/m2m-service-principal.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/auth/
    - https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m
  This file is auto-prepared and human-reviewed before publish.
-->

# Auth Playbook: Common Patterns and Solutions

> Practical reference for configuring Databricks App authentication. Covers scope setup, token lifecycle, deployment patterns, and UC connection governance. Frame this as configuration — all items here describe steps that must be completed, not defects.

---

## Plain-Language Primer

There is **one restaurant** (Databricks) with **one ID check at the door** (your company's identity provider). Everyone — whether they walk in personally or send someone on their behalf — gets verified by the same check.

- **U2M**: you walk in yourself, show your own badge, order, and the kitchen serves *your* meal based on *your* dietary restrictions.
- **OBO**: you're busy, so you send an assistant who shows *your* badge at the same door. The kitchen still serves *your* meal — the assistant just carries the tray.
- **M2M**: your company has a standing catering account. The catering service shows the *company* badge, not any individual's, and gets the standard company order regardless of who placed it.

The door (identity provider) never changes. What changes is whose badge gets shown — and that's the entire distinction between the three paths below.

## Choosing an Auth Path: U2M, OBO, and M2M

Every identity in Databricks — human or application — authenticates against the same identity provider configured at the account level. There is no separate auth system for apps, endpoints, or agents. What differs is **how a token is acquired** for a given call:

| Path | Who authenticates | Identity Unity Catalog sees | Token acquired by |
|---|---|---|---|
| **U2M** (user-to-machine) | The human, directly | The human | The human's own client (CLI, notebook, browser) |
| **OBO** (on-behalf-of) | The human, via an app | The human | An application, forwarding the human's token |
| **M2M** (machine-to-machine) | A service principal | The service principal | The application itself |

Use this to decide which path a given call in your app needs:

- **Result should be scoped to the calling user** (their deals, their quota, row-filtered data) → **OBO**. The app is a pass-through; it forwards the user's token and never substitutes its own identity for a data call.
- **Result is the same for every user** (shared knowledge base, product catalog, background job) → **M2M**. The app's service principal calls on its own behalf.
- **A human is working directly against Databricks** (CLI, notebook, an MCP client like Claude Code or Cursor) → **U2M**. No app in the middle.

### Recommended auth path by component

| Component | Recommended path | How the token arrives |
|---|---|---|
| Genie (via a Databricks App) | OBO | `X-Forwarded-Access-Token` header, forwarded to the Genie API |
| Genie (direct API call) | U2M | Caller's own token in `Authorization: Bearer` |
| Agent Bricks supervisor | OBO | Token auto-forwarded to sub-agents |
| Vector Search | M2M | `WorkspaceClient()` with no arguments (app SP credentials) |
| UC Functions | OBO or M2M | Depends on whether per-user filtering is required |
| Custom MCP server (hosted on a Databricks App) | OBO or M2M | `X-Forwarded-Access-Token` or `WorkspaceClient()` |
| External MCP via a UC connection | M2M or per-user OAuth | Depends on the connection's configured auth method |
| Foundation Model API / Model Serving | M2M | `WorkspaceClient()` with no arguments |
| Lakebase (via a Databricks App) | M2M | OAuth token used as the Postgres password, refreshed via the connection pool |

> **Note on Lakebase**: every other resource in this table is authorized through Unity Catalog (grants, row filters, column masks). Lakebase (Databricks-managed Postgres) uses PostgreSQL-native authorization — roles, `GRANT`, and row-level security policies — so per-user access there is implemented with PG RLS rather than a UC row filter.

---

## Scope Configuration Reference

OAuth scopes control what APIs a user's forwarded (OBO) token can call. Each service requires explicit scope configuration on the app's OAuth integration before it will accept OBO tokens.

| Service | Required Scopes | Where to Configure |
|---|---|---|
| SQL Warehouse (OBO) | `sql` | Account Console → App integrations → User Authorization |
| Genie | `genie`, `dashboards.genie` | Account Console → App integrations → User Authorization (both required) |
| Vector Search | `vector-search` | Account Console → App integrations → User Authorization |
| MLflow / Model Serving | `model-serving` (UI label: `serving.serving-endpoints`) | Account Console → App integrations → User Authorization |
| UC Files / Volumes | `files.files` | Account Console → App integrations → User Authorization |
| Unity Catalog / External MCP connections | `unity-catalog` | Account Console → App integrations → User Authorization |
| MCP Servers (Databricks-hosted) | `all-apis` or the specific endpoint scopes it requires | Account Console → App integrations → User Authorization |
| External HTTP Connections | `USE CONNECTION` privilege on the connection | UC `GRANT` statement |

Add the full set of scopes your app needs on first deploy rather than discovering gaps one tab at a time — extra scopes are harmless, but a missing one surfaces as a 403 with a "required scopes" message.

### Two ways to configure scopes — and why only one produces working OBO tokens

Scopes can be set two ways, and they are not equivalent:

| | CLI (`databricks account custom-app-integration update`) | Account Console → User Authorization (Public Preview) |
|---|---|---|
| Updates the integration's scope list | Yes | Yes |
| Produces an OBO token with those scopes in the JWT `scope` claim | No — sets the integration config, not the effective per-user scopes | Yes |
| Requires user consent | No | Yes — users are prompted to re-authorize on next login |

**How to add scopes (recommended path):**

1. Open **Account Console → App integrations** and select the integration for your app
2. Enable **User Authorization**
3. Select the required scopes from the picker
4. Save — users are prompted to consent and receive an updated OBO token on next login

If you only update scopes via the CLI, the integration's configuration changes but OBO calls that depend on the new scope (for example, OBO SQL) will keep failing until the same scopes are also granted through User Authorization.

---

## "403 Required Scopes" Resolution Guide

A 403 response with "required scopes" in the message body means the user's OBO token does not carry the scope needed for that endpoint. This is a configuration step, not an error in the app code.

### Genie

**Symptom**: `POST /api/genie/<alias>/messages` returns 403. Error message mentions scope validation failure.

**Cause**: The app's OAuth integration is missing one or both Genie scopes. The Genie Conversation API requires the `genie` scope claim on the token in addition to `dashboards.genie`, even on integrations where the scope picker only surfaces `dashboards.genie` as a labeled option.

**Resolution steps**:
1. Open Account Console → App integrations → User Authorization for your app
2. Add `genie` to the scope list
3. Add `dashboards.genie` to the scope list
4. Both scopes must be present. Adding only `dashboards.genie` is insufficient.
5. Have users re-authorize (or wait for the next login cycle) to pick up the new scopes.

### Vector Search

**Symptom**: Vector Search index queries return 403 from within the app.

**Cause**: App integration is missing the `vector-search` scope.

**Resolution steps**:
1. Open Account Console → App integrations → User Authorization
2. Add `vector-search` to the scope list
3. Test by having a user re-authorize and retry the request

### MCP (Databricks-hosted)

**Symptom**: App-to-MCP server calls return 403 when using OBO tokens.

**Cause**: MCP servers with `authorization: enabled` validate the forwarded token against the scopes the MCP app's integration requires.

**Resolution steps**:
1. Identify what scopes the MCP server's app integration requires (check the MCP app's configuration)
2. Add those scopes to the calling app's OAuth integration via User Authorization
3. If the MCP server requires `all-apis`, add that scope. Be aware it grants broad access — prefer specific scopes when the MCP server supports them.

### MLflow / Model Serving

**Symptom**: Serving endpoint queries return 403 from OBO context.

**Cause**: App integration is missing the `model-serving` scope (shown as `serving.serving-endpoints` in the Account Console scope picker).

**Resolution steps**:
1. Open Account Console → App integrations → User Authorization
2. Add `model-serving` (`serving.serving-endpoints`) to the scope list

### External MCP / UC HTTP connections

**Symptom**: Calls through the External MCP proxy (`/api/2.0/mcp/external/...`) return 403 with "Provided OAuth token does not have required scopes: unity-catalog", even though the calling user or service principal already has `USE CONNECTION` on the connection.

**Cause**: The External MCP proxy checks the `USE CONNECTION` privilege using the `unity-catalog` scope specifically. Holding the privilege is not enough if the token itself lacks the scope.

**Resolution steps**:
1. Add `unity-catalog` to the app's OAuth integration via User Authorization
2. Confirm the calling identity (user or SP) also has `USE CONNECTION` on the target connection (see [GRANT/REVOKE Patterns](#grantrevoke-patterns) below)

### UC Connections (USE CONNECTION)

**Symptom**: Calls to external services via `external-function` API return 403 with a privilege error.

**Cause**: The calling user or the app's service principal lacks `USE CONNECTION` privilege on the UC connection.

**Resolution steps**:
```sql
-- Grant to a specific user
GRANT USE CONNECTION ON CONNECTION <connection_name> TO `user@example.com`;

-- Grant to a group (preferred for role-based access)
GRANT USE CONNECTION ON CONNECTION <connection_name> TO `<group_name>`;

-- Grant to the app service principal (for M2M calls)
GRANT USE CONNECTION ON CONNECTION <connection_name>
  TO `<app-sp-application-uuid>`;
```

Verify after granting:
```sql
SHOW GRANTS ON CONNECTION <connection_name>;
```

---

## current_user() vs is_member() in Row Filters and Column Masks

When the same tables are read through U2M, OBO, and M2M paths, `current_user()` and `is_member()` do not behave the same way — and picking the wrong one is the most common cause of unexpected row-filter or column-mask results in AI apps.

| Function | Evaluates | U2M | OBO (through Genie / Agent Bricks) | M2M |
|---|---|---|---|---|
| `current_user()` | The authenticated identity | Human email | Human email — Genie/Agent Bricks explicitly inject the OBO caller's identity | SP application UUID |
| `is_member('group')` | The SQL execution context's group membership | Human's groups (correct) | The execution service's identity, not the human asking the question | SP's workspace-group membership (correct if the SP is in the group) |

**Why `is_member()` looks wrong in OBO**: it evaluates the identity that is actually executing the SQL. In Genie and Agent Bricks, that's the serving identity, not the human whose question triggered it. `current_user()` works because Genie and Agent Bricks explicitly propagate the OBO caller's email into that function's context.

**Rule of thumb**: if a table is queried across U2M, OBO, and M2M paths, standardize on `current_user()`. Reserve `is_member()` for paths that are exclusively U2M or exclusively M2M.

**Pattern for an OBO-safe column mask** (works consistently across OBO and M2M):

```sql
CREATE OR REPLACE FUNCTION my_catalog.my_schema.mask_quota(val DECIMAL(12,2))
  RETURNS DECIMAL(12,2)
  RETURN IF(
    EXISTS (SELECT 1 FROM my_catalog.my_schema.privileged_users WHERE user_email = current_user()),
    val, NULL
  );
-- privileged_users is a UC-governed allowlist table of user emails (or SP UUIDs) with elevated access
```

---

## Token Lifecycle

### OBO Token Expiry and Refresh

OBO tokens are issued by the Databricks Apps proxy when a user accesses the app. Token lifetime is governed by the workspace OAuth configuration (typically 1 hour).

The proxy automatically refreshes tokens for active sessions. App code does not need to manage refresh explicitly — `X-Forwarded-Access-Token` contains a valid token for the duration of each request.

If a user's session expires while the app is open, the next request will receive a 401. The standard pattern is to redirect to the app root, which triggers re-authentication through the proxy.

### Reading the OBO token by runtime

The correct way to obtain the calling user's token depends on where your code runs — using the wrong method for the runtime resolves quietly to the app's service principal identity instead of the user's:

| Runtime | Read the OBO token via | Notes |
|---|---|---|
| Databricks Apps (Streamlit) | `st.context.headers.get("X-Forwarded-Access-Token")` | Use `st.context.headers`, not `request.headers` (the Flask pattern doesn't apply here) |
| Databricks Apps (any framework) | The `X-Forwarded-Access-Token` request header | Normalize `X-Forwarded-Host` to include `https://` — it can arrive without a scheme |
| Model Serving (Agent Bricks) | `ModelServingUserCredentials()` credential strategy | Reads from the Model Serving request context — intended for code running inside a serving endpoint, not inside a Databricks App |

**Add a canary check** to confirm which identity your app is actually using, especially if a code sample was adapted from a Model Serving example:

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.credentials_provider import ModelServingUserCredentials

w = WorkspaceClient(credentials_strategy=ModelServingUserCredentials())
identity = w.current_user.me().user_name
if "@" not in identity:
    # Resolves to the app's service principal, not a human — read the
    # X-Forwarded-Access-Token header directly instead when running in a Databricks App.
    raise RuntimeError(f"Expected a user identity, got: {identity}")
```

### App-to-app calls (two proxies)

When one Databricks App calls another (for example, a Streamlit app calling a custom MCP server hosted as its own Databricks App), the request passes through two proxies. The second proxy re-issues `X-Forwarded-Access-Token` as its own app's service-principal token rather than passing the original user's token through — so the receiving app cannot rely on that header for the human's identity. It can, however, rely on `X-Forwarded-Email`, which the second proxy sets from the validated incoming token and which the calling app cannot forge.

**Pattern**: read `X-Forwarded-Email` for the caller's identity, then use the receiving app's own service-principal (M2M) credentials for the data call, applying the same per-user filter explicitly that a UC row filter would otherwise apply:

```python
# Pure ASGI middleware — required so identity propagates through async context correctly
class ExtractCallerMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = {k.lower(): v for k, v in scope.get("headers", [])}
            caller_email = headers.get(b"x-forwarded-email", b"").decode("utf-8")
            # store caller_email in a ContextVar for use inside the tool handler
        await self.app(scope, receive, send)

def get_my_records(caller_email: str) -> dict:
    w = WorkspaceClient()  # M2M — app service principal
    rows = run_sql(w, f"""
        SELECT id, value
        FROM   my_catalog.my_schema.records
        WHERE  owner_email = '{caller_email.replace("'", "''")}'  -- explicit per-user filter
        LIMIT  50
    """)
    return {"caller": caller_email, "rows": rows}
```

This pattern needs no additional OAuth scope on the receiving app — identity comes from the trusted header, and the M2M client already has the SQL access it needs.

### UC Connection Token Auto-Refresh (OAuth U2M Per User)

For UC connections using OAuth U2M Per User, Databricks manages the external service tokens. The platform stores and automatically refreshes each user's token when it nears expiry.

The app code does not need refresh logic. If an external service token has expired and cannot be refreshed (e.g., the user revoked the OAuth grant at the external service), the `external-function` call returns a 401 or 403 from the connection layer. The app should surface this as a re-authorization prompt.

### When Users Need to Re-Authorize

| Trigger | Re-auth required? | Where |
|---|---|---|
| New scope added to app integration | Yes, for new scope features | Automatic on next login |
| User's session expires | Yes | Automatic redirect to app root |
| User revokes OAuth grant at external service | Yes | User must re-authorize at external service via app prompt |
| UC connection credential rotated (Bearer Token) | No | Connection update is transparent to users |
| `REVOKE USE CONNECTION` executed | No re-auth; access denied immediately | GRANT must be re-issued to restore access |

---

## Deployment Patterns

### Raw Source Deploy

AppKit supports deploying TypeScript source directly. The `databricks apps deploy` command handles the build:

```bash
databricks apps deploy --app-name <app-name>
```

The CLI runs `npm install` and your `build` script, then uploads the result. This works when the workspace has network access to the npm registry.

### Bundled Deploy

When the workspace cannot reach the npm registry (air-gapped, restricted egress), pre-bundle locally and deploy the `build/` directory:

```bash
# Local machine (network access)
npm install
npm run build

# Deploy pre-built artifacts
databricks apps deploy --app-name <app-name>
```

The built output should include `build/index.mjs` (server bundle) and `build/client/` (static assets). Confirm your `build` script produces this layout.

### package.json Handling

AppKit server code runs at deploy time. All runtime dependencies must be in `dependencies`, not `devDependencies`. Verify before deploy:

- `@databricks/appkit` → `dependencies`
- `@databricks/appkit-ui` → `dependencies` (if server imports it)
- `express`, `tsx`, type packages → `devDependencies` (not needed at runtime if bundled)

For bundled deploys (`esbuild --bundle`), dependencies are inlined. For raw source deploys, the platform runs `npm install --production`, so `devDependencies` are excluded.

### Post-Deploy Permission Grants

After deploying a new app, complete these permission grants before testing:

```sql
-- Allow app SP to use the warehouse
GRANT CAN_USE ON SQL WAREHOUSE <warehouse-id>
  TO `<app-service-principal>`;

-- Allow app SP to run Genie (if using Genie plugin)
GRANT CAN_RUN ON GENIE SPACE <space-id>
  TO `<app-service-principal>`;

-- Allow target users/groups to reach external services
GRANT USE CONNECTION ON CONNECTION <connection-name>
  TO `<group-name>`;
```

The app service principal name is visible in Workspace Settings → Service Principals. It is auto-created when the app is deployed and named after the app.

---

## GRANT/REVOKE Patterns

UC connections are the governance control plane for external service access. GRANT and REVOKE take effect immediately — no redeploy, no code changes, no user re-authorization required.

### UC Connection Governance

```sql
-- Check current grants on a connection
SHOW GRANTS ON CONNECTION <connection_name>;

-- Grant access to a user
GRANT USE CONNECTION ON CONNECTION <connection_name>
  TO `user@example.com`;

-- Grant access to a group (preferred)
GRANT USE CONNECTION ON CONNECTION <connection_name>
  TO `sales_west`;

-- Revoke access from a user
REVOKE USE CONNECTION ON CONNECTION <connection_name>
  FROM `user@example.com`;

-- Revoke access from a group
REVOKE USE CONNECTION ON CONNECTION <connection_name>
  FROM `contractor_group`;
```

### Per-Service Examples

**Salesforce (OAuth U2M Per User)**

```sql
-- Grant: user can query Salesforce through the app
GRANT USE CONNECTION ON CONNECTION salesforce_u2m_conn
  TO `sales_west`;

-- Revoke: user's Salesforce access via app is cut immediately
REVOKE USE CONNECTION ON CONNECTION salesforce_u2m_conn
  FROM `departed_employee@example.com`;
```

Note: Revoking `USE CONNECTION` does not delete the user's stored Salesforce tokens — it prevents the connection from being used via the external-function API. The stored tokens remain in Databricks but cannot be exercised.

**GitHub MCP (Managed OAuth U2M)**

```sql
GRANT USE CONNECTION ON CONNECTION ai_gov_github_conn
  TO `engineering_team`;

REVOKE USE CONNECTION ON CONNECTION ai_gov_github_conn
  FROM `intern_group`;
```

**Custom MCP / Bearer Token Connection**

```sql
-- Bearer token connections: all users share the same credential
-- Access control is entirely via USE CONNECTION privilege
GRANT USE CONNECTION ON CONNECTION ai_gov_custmcp_conn
  TO `approved_users`;

REVOKE USE CONNECTION ON CONNECTION ai_gov_custmcp_conn
  FROM `trial_group`;
```

For bearer token connections, there is no per-user token. GRANT/REVOKE is the only access control mechanism — there is no user-level token to revoke at the external service.

### Verifying Access Changes

After a GRANT or REVOKE, verify with:

```sql
SHOW GRANTS ON CONNECTION <connection_name>;
```

For applications that surface live GRANT/REVOKE controls (like the ConnectionsTab pattern), the change is visible immediately in the next call to `SHOW GRANTS`.

### Bulk Access Review

To audit all connections in a catalog:

```sql
SHOW CONNECTIONS IN CATALOG <catalog_name>;
```

Then check each connection's grants individually. There is no single system table that joins connections to grants across a catalog in a single query — check each connection by name.

---

## Service Principal Identity and Governance

### An app's service principal has two identifiers

- **Application UUID** — what `current_user()` returns in SQL and what UC grants target
- **User/member ID** — the numeric ID used for SCIM group operations

Find the SP's member ID from its application UUID:

```bash
databricks api get /api/2.0/preview/scim/v2/ServicePrincipals \
  --profile <workspace-profile> \
  | jq '.Resources[] | select(.applicationId == "<application-uuid>") | .id'
```

### Grant through groups, not directly to the SP

For pipelines, gateways, and background jobs, grant UC privileges to a workspace group and add the service principal to that group, rather than granting to the SP directly:

```sql
GRANT USE CATALOG ON CATALOG prod TO `pipeline-readers`;
GRANT USE SCHEMA ON SCHEMA prod.bronze TO `pipeline-readers`;
GRANT SELECT ON TABLE prod.bronze.sales_raw TO `pipeline-readers`;
```

This makes access changes a group-membership operation instead of a privilege-by-privilege one:

- Removing the SP from the group is an instant, complete access cutoff
- Rotating the SP's secret has no effect on its privileges
- A second SP (blue-green deploys, for example) inherits access with one group addition
- Audit logs show group-membership changes separately from data-access events

Give each service its own SP and its own group (`pipeline-readers`, `api-gateway`, `compliance-reporters`) rather than sharing one SP across services.

`is_member()` checks against this pattern only resolve correctly when the SP is in the **workspace** group — account-level group membership alone is not enough:

```sql
CREATE OR REPLACE FUNCTION rls_compliance(val STRING)
RETURNS STRING
RETURN IF(is_member('compliance-reporters'), val, NULL);
```

### Client credentials for external services

Databricks Apps inject SP credentials into the runtime automatically. External services — pipelines, API gateways, jobs running outside Databricks Apps — obtain a token explicitly via the OAuth 2.0 client credentials flow:

```http
POST https://<workspace-host>/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=<sp-application-uuid>
&client_secret=<sp-secret>
&scope=all-apis
```

The token is valid for 1 hour — cache it and refresh proactively rather than requesting a new one per call. Use the narrowest `scope` the caller needs (`sql`, `clusters`, `jobs`, or `all-apis`).

### Secret management

Store SP credentials for external services in a Databricks secret scope rather than in plaintext env vars, code repositories, or unmanaged CI/CD variables:

```bash
databricks secrets create-scope pipeline-sp --profile <profile>
databricks secrets put-secret pipeline-sp client-id --string-value <uuid> --profile <profile>
databricks secrets put-secret pipeline-sp client-secret --string-value <secret> --profile <profile>
```

Back the scope with your cloud's key management service in production (AWS Secrets Manager, Azure Key Vault, or GCP Secret Manager).

Each SP has a limited number of active secrets available at a time. If you hit a secret-creation limit, list and clean up stale secrets from earlier testing before generating a new one:

```bash
databricks api get /api/2.0/accounts/<account-id>/service-principals/<sp-id>/credentials/secrets \
  --profile <account-profile>
```

### Auditing SP activity

SP identity appears in `system.access.audit` like any other principal (`user_identity.email` holds the application UUID for an SP rather than an email address):

```sql
-- Data access actions by a specific SP in the last 7 days
SELECT event_time, action_name, request_params, response
FROM system.access.audit
WHERE user_identity.email = '<sp-application-uuid>'
  AND event_date >= current_date() - 7
ORDER BY event_time DESC;

-- Group membership changes for governance groups
SELECT event_time, action_name, request_params
FROM system.access.audit
WHERE action_name IN ('updateGroup', 'addMembersToGroup', 'removeMembersFromGroup')
  AND request_params:group_name IN ('pipeline-readers', 'api-gateway', 'compliance-reporters')
ORDER BY event_time DESC;
```

---

## Related

- Databricks authentication overview: https://docs.databricks.com/aws/en/dev-tools/auth/
- OAuth machine-to-machine (client credentials) reference: https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m
- [`appkit-auth-patterns.md`](appkit-auth-patterns.md) — AppKit-specific auth wiring
- [`u2m-external-obo.md`](u2m-external-obo.md) — U2M and external OBO federation patterns
- [`oauth-scopes-reference.md`](oauth-scopes-reference.md) — full scope reference
