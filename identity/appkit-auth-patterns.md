# AppKit Auth Patterns: OBO, U2M, and UC Connections

> Reference architecture for building Databricks Apps that combine multiple auth patterns in a single application. Covers OBO SQL + Genie, OAuth U2M per-user external services, Bearer Token shared credentials, and UC connection governance.

## Overview

A single Databricks App can serve multiple access patterns simultaneously — aggregate data visible to all, user-scoped data enforced by Unity Catalog, and external services reached through UC HTTP connections. AppKit makes this composition straightforward through its plugin system and query file naming conventions.

The three patterns address distinct governance questions:

| Pattern | Who does Databricks see? | Use when |
|---|---|---|
| **OBO** | The human user (email) | Internal data, row filters, per-user Genie |
| **OAuth U2M Per User** | The human user at the external service | External SaaS with per-user OAuth (Salesforce, etc.) |
| **Bearer Token** | A shared service account | Internal or partner services with shared credentials |

All three are governed by UC connections — a single `GRANT`/`REVOKE` controls access without code changes.

---

## Architecture

```
Browser (Databricks App user)
    |
    v
+-------------------------------------------+
|  Databricks Apps Proxy                    |
|  - Authenticates user via workspace IdP   |
|  - Injects X-Forwarded-Access-Token       |
|  - Injects X-Forwarded-User               |
+-------------------------------------------+
    |
    v
+-------------------------------------------+
|  AppKit Server (Express + TypeScript)     |
|                                           |
|  server()     -- HTTP, health, static     |
|  analytics()  -- SQL (SP + OBO)           |
|  genie()      -- Genie spaces (OBO)       |
|  salesforce() -- custom plugin (U2M)      |
|  connections()-- custom plugin (GRANT)    |
+-------------------------------------------+
    |             |                |
    v             v                v
Databricks    Databricks     Databricks
SQL Warehouse  Genie API      external-function
(OBO/SP)       (OBO)          API
                              |
                    +---------+---------+
                    |         |         |
               Salesforce  GitHub   Custom MCP
               (U2M/user)  (U2M)    (Bearer)
```

The Databricks Apps proxy handles user authentication before requests reach the app. The app never manages user passwords, sessions, or IdP integration directly.

---

## Three Auth Patterns

### Pattern 1: OBO (On-Behalf-Of User) — SQL + Genie

OBO forwards the user's token to Databricks services. `current_user()` returns the human's email. UC row filters and column masks fire per individual identity.

**How it works in AppKit**

The `.obo.sql` file naming convention is the entire API surface for SQL:

```
config/queries/
  sales_summary.sql        # executes as SP, shared result cache
  my_pipeline.obo.sql      # executes as calling user, per-user cache
```

The `analytics()` plugin detects the `.obo.sql` suffix and reads `X-Forwarded-Access-Token` from the request headers, passing it as the warehouse credential. No additional code required.

On the React side:

```typescript
import { useAnalyticsQuery } from "@databricks/appkit-ui/react";
import { useMemo } from "react";

// SP query — all users see same aggregate, no row filters
const params = useMemo(() => ({}), []);
const summary = useAnalyticsQuery("sales_summary", params);

// OBO query — UC row filters apply per current user
const pipeline = useAnalyticsQuery("my_pipeline", params);
```

`useAnalyticsQuery` automatically routes OBO queries with the user token. The query key maps to the filename without extension.

**Genie (OBO)**

Genie always runs OBO. Configure named spaces in the plugin, then call by alias:

```typescript
// server.ts
genie({
  spaces: {
    sales: process.env.GENIE_SPACE_ID || "<space-id>",
  },
})
```

```typescript
// Frontend: POST /api/genie/sales/messages
const resp = await fetch("/api/genie/sales/messages", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ content: userMessage, conversationId }),
});
```

AppKit streams SSE events: `message_start`, `status`, `message_result`, `query_result`. The Genie plugin reads `X-Forwarded-Access-Token` internally — no explicit token handling in app code.

**Data flow (OBO)**

```
User request
    --> Databricks Apps proxy adds X-Forwarded-Access-Token
    --> AppKit reads header
    --> Passes token to SQL warehouse / Genie API
    --> current_user() = human email
    --> UC row filters fire per individual
    --> Result returned (scoped to that user's access)
```

---

### Pattern 2: OAuth U2M Per User — External Services (Salesforce)

UC HTTP connections with OAuth U2M store each user's external service tokens in Databricks. The app proxies calls through `POST /api/2.0/external-function` using the user's own Databricks token — Databricks exchanges it for the stored per-user external token.

**How it works**

A UC HTTP connection of type `OAUTH_U2M` manages the OAuth consent flow and token storage. The app never sees Salesforce credentials.

```
User request (user's Databricks OBO token)
    --> App calls /api/2.0/external-function
            { connection_name, method, path }
    --> Databricks looks up user's Salesforce token for this connection
    --> If not found: returns 401, user must authorize via Databricks OAuth flow
    --> If found (and valid): proxies call to Salesforce API
    --> Returns Salesforce response to app
    --> App returns to client
```

**Custom plugin pattern**

```typescript
// server/plugins/salesforce.ts
class SalesforcePlugin extends Plugin {
  static manifest = {
    name: "salesforce",
    displayName: "Salesforce",
    description: "Query Salesforce via UC HTTP connection (OAuth U2M Per User)",
    resources: { required: [], optional: [] },
  };

  private get connectionName(): string {
    return (this.config as any).connectionName || "salesforce_u2m_conn";
  }

  override injectRoutes(router: express.Router): void {
    this.route(router, {
      name: "query",
      method: "post",
      path: "/query",
      handler: async (req, res) => {
        const { soql } = req.body;
        const token = req.headers["x-forwarded-access-token"] as string;
        const data = await this.callExternal("GET",
          `/query?q=${encodeURIComponent(soql)}`, token);
        res.json(data);
      },
    });
  }

  private async callExternal(method: string, path: string, token: string) {
    const host = process.env.DATABRICKS_HOST || "";
    const normalizedHost = host.startsWith("http") ? host : `https://${host}`;

    const resp = await fetch(`${normalizedHost}/api/2.0/external-function`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        connection_name: this.connectionName,
        method: method.toUpperCase(),
        path,
      }),
    });
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`External service error (${resp.status}): ${errText}`);
    }
    return resp.json();
  }
}
```

**Key detail**: `DATABRICKS_HOST` must include the `https://` scheme. Normalize explicitly — the environment variable may or may not include it depending on how the workspace was configured.

**User experience**: The first time a user accesses Salesforce via the app, Databricks prompts them to authorize. After that, their token is stored and auto-refreshed. Subsequent calls are seamless.

---

### Pattern 3: Bearer Token — Shared Credentials

Some services use a shared service account token stored in the UC connection. All users of the connection share the same external credential. Access is governed entirely by `USE CONNECTION` privilege — remove the privilege and the user cannot call the service.

**How it works**

The UC connection stores a static bearer token. The `external-function` API injects it as `Authorization: Bearer <token>` when calling the external service. App code passes the user's OBO token to authenticate the external-function call, but the external service sees the shared credential.

```typescript
// connections.ts — same external-function pattern, different connection type
const resp = await fetch(`${host}/api/2.0/external-function`, {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${userOboToken}`,  // auth to Databricks
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    connection_name: "ai_gov_custmcp_conn",     // connection carries the bearer token
    method: "GET",
    path: "/",
  }),
});
```

**When to use Bearer Token vs U2M**

| Consideration | Bearer Token | OAuth U2M Per User |
|---|---|---|
| External service identity | Shared SP/bot account | Each user's own account |
| Audit trail at external service | Single account | Individual users |
| Token rotation | Manual (update connection) | Automatic (Databricks manages) |
| Setup complexity | Low | Higher (OAuth app registration) |
| Per-user entitlements at external service | No | Yes |

Bearer Token is appropriate when: the external service doesn't support per-user OAuth, you want a single audit identity at the external service, or the service is internal.

---

## UC Governance Layers

UC provides multiple enforcement points that work together regardless of which auth pattern is active.

### Layer 1: Table-Level Grants

```sql
-- Grant SELECT on a table to a group
GRANT SELECT ON TABLE applied_ai_gov.sales.opportunities TO `west_sales`;

-- Revoke access entirely
REVOKE SELECT ON TABLE applied_ai_gov.sales.opportunities FROM `east_sales`;
```

### Layer 2: Row Filters (OBO-enforced)

When a query runs OBO, `current_user()` returns the human's email. Row filters can use group membership:

```sql
-- Row filter: users only see their region's data
CREATE FUNCTION applied_ai_gov.sales.region_filter(region STRING)
RETURNS BOOLEAN
RETURN is_account_group_member('west_sales') OR current_user() = 'admin@example.com';

ALTER TABLE applied_ai_gov.sales.opportunities
SET ROW FILTER applied_ai_gov.sales.region_filter ON (region);
```

**Critical**: Row filters only enforce per individual identity when the query runs OBO. SP-executed queries (`sales_summary.sql`, not `.obo.sql`) run as the app's service principal, bypassing individual row filters. This is intentional for aggregate queries that should show totals across all regions.

### Layer 3: Column Masks

```sql
-- Mask sensitive columns for non-privileged users
CREATE FUNCTION applied_ai_gov.sales.mask_margin(margin DOUBLE)
RETURNS DOUBLE
RETURN IF(is_account_group_member('sales_managers'), margin, NULL);

ALTER TABLE applied_ai_gov.sales.opportunities
SET MASK applied_ai_gov.sales.mask_margin ON COLUMN (margin_pct);
```

### Layer 4: USE CONNECTION Privilege

Every UC connection requires `USE CONNECTION` privilege. This is the governance control plane for external service access:

```sql
-- Grant access to a Salesforce connection
GRANT USE CONNECTION ON CONNECTION salesforce_u2m_conn TO `west_sales`;

-- Revoke instantly — no code changes, no redeploy
REVOKE USE CONNECTION ON CONNECTION salesforce_u2m_conn FROM `contractor_group`;
```

Without `USE CONNECTION`, calls to `external-function` return 403 immediately, regardless of whether the user has a valid Salesforce token.

---

## Scope Configuration

Databricks OAuth scopes control what APIs a token can call. Each service requires specific scopes added to the app's OAuth integration.

### Required Scopes by Service

| Service | Required Scopes | Notes |
|---|---|---|
| SQL Warehouse (OBO) | `sql` | Included in default app integration |
| Genie (OBO) | `genie`, `dashboards.genie` | **Both required** — platform checks for `genie` scope even when the UI only shows `dashboards.genie` |
| Vector Search | `vector-search` | Add explicitly if using embedding lookups |
| MCP Servers (external) | `all-apis` or specific endpoint scopes | Depends on MCP server's auth requirements |
| MLflow / Model Serving | `serving-endpoints` | Add if app queries serving endpoints directly |
| Files / Volumes | `files` | Required for Files plugin |

### How to Add Scopes

Navigate to: **Workspace Settings → Developer → App Integrations → [your app's integration] → Scopes**

Add each required scope. Changes take effect immediately for new user authorizations. Existing sessions may need to re-authorize if the scope was previously absent.

For the Genie pattern specifically, add both `genie` and `dashboards.genie`. The OAuth consent screen only shows `dashboards.genie` as a user-facing label, but the platform token validator checks for the `genie` scope claim.

---

## AppKit Conventions

### Query File Naming

```
config/queries/
  <key>.sql          # service principal execution
  <key>.obo.sql      # OBO execution (user identity propagated)
```

The key is the filename without extension (or `.obo.sql` suffix). Call it with `useAnalyticsQuery("<key>", params)` on the frontend regardless of execution mode — the SDK routes appropriately.

### Plugin Routing

Custom plugins register routes under `/api/<pluginName>/<routeName>`:

```typescript
// Plugin name: "salesforce" → routes at /api/salesforce/...
// Plugin name: "connections" → routes at /api/connections/...

this.route(router, {
  name: "query",      // POST /api/salesforce/query
  method: "post",
  path: "/query",
  handler: async (req, res) => { ... },
});
```

### Token Extraction

Read the OBO token in custom plugins:

```typescript
const token = (req.headers["x-forwarded-access-token"] as string)
  || process.env.DATABRICKS_TOKEN
  || "";
```

The fallback to `DATABRICKS_TOKEN` supports local development. In production, `x-forwarded-access-token` is always present for authenticated users.

### Host Normalization

```typescript
function getHost(): string {
  const h = process.env.DATABRICKS_HOST || "";
  return h.startsWith("http") ? h : `https://${h}`;
}
```

Always normalize before making API calls. `DATABRICKS_HOST` is inconsistently set with or without `https://` across environments.

---

## App Template Structure

```
appkit-ai-gov/
  server/
    server.ts              # plugin composition entry point
    plugins/
      salesforce.ts        # custom plugin: U2M external calls
      connections.ts       # custom plugin: GRANT/REVOKE demo
  client/
    index.html
    vite.config.ts
    tsconfig.json
    src/
      main.tsx
      App.tsx              # tab routing
      tabs/
        SalesAnalytics.tsx # useAnalyticsQuery (SP + OBO)
        GenieTab.tsx       # SSE streaming (OBO)
        SalesforceTab.tsx  # external-function API (U2M)
        ConnectionsTab.tsx # GRANT/REVOKE UI (governance)
  config/
    queries/
      sales_summary.sql        # SP: aggregate, no row filters
      my_pipeline.obo.sql      # OBO: per-user, row filters apply
      my_accounts.obo.sql      # OBO: account-level view
  app.yaml                     # resources, env vars
  package.json
  tsconfig.json
```

**`server.ts` — complete plugin composition:**

```typescript
import { createApp, server, analytics, genie } from "@databricks/appkit";
import { salesforce } from "./plugins/salesforce.js";
import { connections } from "./plugins/connections.js";

await createApp({
  plugins: [
    server(),
    analytics(),
    genie({
      spaces: {
        sales: process.env.GENIE_SPACE_ID || "<space-id>",
      },
    }),
    salesforce({
      connectionName: process.env.SALESFORCE_CONN || "salesforce_u2m_conn",
    }),
    connections({
      connections: {
        salesforce: process.env.SALESFORCE_CONN || "salesforce_u2m_conn",
        github: process.env.GITHUB_CONN || "ai_gov_github_conn",
        custmcp: process.env.CUSTMCP_CONN || "ai_gov_custmcp_conn",
      },
    }),
  ],
});
```

**`app.yaml` — resources declaration:**

```yaml
command:
  - node
  - build/index.mjs

env:
  - name: DATABRICKS_WAREHOUSE_ID
    value: "<warehouse-id>"
  - name: GENIE_SPACE_ID
    value: "<space-id>"
  - name: SALESFORCE_CONN
    value: "salesforce_u2m_conn"

resources:
  - sql_warehouse:
      id: "<warehouse-id>"
      permission: CAN_USE
  - genie:
      id: "<space-id>"
      permission: CAN_RUN
```

UC connections are governed via GRANT/REVOKE, not declared in `app.yaml`.

---

## Deployment Checklist

### Pre-Deploy

- [ ] `DATABRICKS_WAREHOUSE_ID` set in `app.yaml` env section
- [ ] `GENIE_SPACE_ID` set in `app.yaml` env section (if using Genie)
- [ ] `sql_warehouse` and `genie` resources declared in `app.yaml` with correct IDs
- [ ] UC connections created (`salesforce_u2m_conn`, etc.) before app deploy
- [ ] `package.json` includes all dependencies (no `devDependencies`-only packages used at runtime)
- [ ] Build script produces `build/index.mjs` (server) and `build/client/` (static assets)

### Scope Configuration

- [ ] App OAuth integration has `sql` scope
- [ ] If using Genie: add both `genie` AND `dashboards.genie` to app integration scopes
- [ ] If using Vector Search: add `vector-search`
- [ ] If using Files plugin: add `files`

### Post-Deploy

- [ ] Grant app service principal `CAN_USE` on SQL warehouse
- [ ] Grant app service principal `CAN_RUN` on Genie space
- [ ] Grant `USE CONNECTION` on each UC connection to target groups/users
- [ ] Verify OBO queries return user-scoped data (not SP results)
- [ ] Verify Genie chat runs under user identity (check audit log)
- [ ] Test `GRANT`/`REVOKE` on connections and confirm access changes immediately

### UC Governance Verification

```sql
-- Verify connection grants
SHOW GRANTS ON CONNECTION salesforce_u2m_conn;

-- Verify row filter is applied
DESCRIBE EXTENDED applied_ai_gov.sales.opportunities;

-- Verify current_user() propagation (run as test user)
SELECT current_user();
```

---

## Troubleshooting

### 403 on Genie endpoint

**Symptom**: Genie calls return 403 with "required scopes" in the message.
**Cause**: App OAuth integration is missing the `genie` scope.
**Resolution**: Add `genie` AND `dashboards.genie` to the app integration's scope list in Workspace Settings → Developer → App Integrations.

### SP results showing instead of OBO results

**Symptom**: `useAnalyticsQuery("my_query", params)` returns data that doesn't respect row filters.
**Cause**: Query file is named `my_query.sql` instead of `my_query.obo.sql`.
**Resolution**: Rename the file to `my_query.obo.sql`. OBO execution is controlled entirely by the `.obo.sql` suffix.

### Salesforce / external service calls return 403

**Symptom**: Calls through UC connection fail with "Principal does not have USE CONNECTION privilege."
**Cause**: The calling user (or app SP) lacks `USE CONNECTION` on the connection.
**Resolution**:
```sql
GRANT USE CONNECTION ON CONNECTION salesforce_u2m_conn TO `user@example.com`;
-- or for a group:
GRANT USE CONNECTION ON CONNECTION salesforce_u2m_conn TO `west_sales`;
```

### DATABRICKS_HOST missing scheme

**Symptom**: `fetch` calls fail with invalid URL errors in local dev.
**Cause**: `DATABRICKS_HOST` env var is set without `https://` prefix.
**Resolution**: Normalize in plugin code — `h.startsWith("http") ? h : \`https://${h}\``. Do not assume the format.

### OBO token not forwarded to custom plugin

**Symptom**: Custom plugin calls external APIs with empty or incorrect token.
**Cause**: Plugin code reads `req.headers["x-forwarded-access-token"]` but the header key casing differs.
**Resolution**: Express lowercases all incoming header names. Use `"x-forwarded-access-token"` (all lowercase).

### Row filters not applying

**Symptom**: OBO queries return all rows regardless of user.
**Cause**: Row filter function or column mask not attached to the table, or query is running as SP (`.sql` not `.obo.sql`).
**Resolution**: Verify with `DESCRIBE EXTENDED <table>` that the row filter is set. Verify the query file has the `.obo.sql` suffix.
