# Auth Playbook: Common Patterns and Solutions

> Practical reference for configuring Databricks App authentication. Covers scope setup, token lifecycle, deployment patterns, and UC connection governance. Frame this as configuration — all items here describe steps that must be completed, not defects.

---

## Scope Configuration Reference

OAuth scopes control what APIs a user's forwarded token can call. Each service requires explicit scope configuration on the app's OAuth integration before it will accept OBO tokens.

| Service | Required Scopes | Where to Configure |
|---|---|---|
| SQL Warehouse (OBO) | `sql` | App OAuth integration |
| Genie | `genie`, `dashboards.genie` | App OAuth integration (both required) |
| Vector Search | `vector-search` | App OAuth integration |
| MLflow / Model Serving | `serving-endpoints` | App OAuth integration |
| UC Files / Volumes | `files` | App OAuth integration |
| MCP Servers (Databricks-hosted) | `all-apis` or specific endpoint scopes | App OAuth integration |
| External HTTP Connections | `USE CONNECTION` privilege on the connection | UC GRANT statement |

**How to add scopes:**

1. Navigate to **Workspace Settings → Developer → App Integrations**
2. Select the integration associated with your app
3. Open the **Scopes** panel
4. Add each required scope from the table above
5. Save. Changes apply to new user authorization flows immediately.

Users who authorized before a scope was added may need to re-authorize. This happens automatically on next login if the scope is required for a feature they access.

---

## "403 Required Scopes" Resolution Guide

A 403 response with "required scopes" in the message body means the user's OBO token does not carry the scope needed for that endpoint. This is a configuration step, not an error in the app code.

### Genie

**Symptom**: `POST /api/genie/<alias>/messages` returns 403. Error message mentions scope validation failure.

**Cause**: The app's OAuth integration is missing one or both Genie scopes. The platform requires the `genie` scope claim on the token even though the UI scope selector only displays `dashboards.genie` as a label.

**Resolution steps**:
1. Open Workspace Settings → Developer → App Integrations
2. Find the integration for your app
3. Add `genie` to the scope list
4. Add `dashboards.genie` to the scope list
5. Both scopes must be present. Adding only `dashboards.genie` is insufficient.
6. Redeploy or wait for the next user login cycle to pick up the new scopes.

### Vector Search

**Symptom**: Vector Search index queries return 403 from within the app.

**Cause**: App integration is missing the `vector-search` scope.

**Resolution steps**:
1. Open Workspace Settings → Developer → App Integrations
2. Add `vector-search` to the scope list
3. Test by having a user re-authorize and retry the request

### MCP (Databricks-hosted)

**Symptom**: App-to-MCP server calls return 403 when using OBO tokens.

**Cause**: MCP servers with `authorization: enabled` validate the forwarded token against the scopes the MCP app's integration requires.

**Resolution steps**:
1. Identify what scopes the MCP server's app integration requires (check the MCP app's configuration)
2. Add those scopes to the calling app's OAuth integration
3. If the MCP server requires `all-apis`, add that scope. Be aware it grants broad access — prefer specific scopes when the MCP server supports them.

### MLflow / Model Serving

**Symptom**: Serving endpoint queries return 403 from OBO context.

**Cause**: App integration is missing `serving-endpoints` scope.

**Resolution steps**:
1. Open Workspace Settings → Developer → App Integrations
2. Add `serving-endpoints` to the scope list

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

## Token Lifecycle

### OBO Token Expiry and Refresh

OBO tokens are issued by the Databricks Apps proxy when a user accesses the app. Token lifetime is governed by the workspace OAuth configuration (typically 1 hour).

The proxy automatically refreshes tokens for active sessions. App code does not need to manage refresh explicitly — `x-forwarded-access-token` contains a valid token for the duration of each request.

If a user's session expires while the app is open, the next request will receive a 401. The standard pattern is to redirect to the app root, which triggers re-authentication through the proxy.

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
  TO `west_sales`;

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
  TO `west_sales`;

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
