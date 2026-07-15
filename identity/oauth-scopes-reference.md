<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/oauth-scopes.md
  Public docs grounding:
    - https://docs.databricks.com/api/workspace/api/scopes
    - https://docs.databricks.com/api/account/api/scopes
  This file is auto-prepared and human-reviewed before publish.
-->

# OAuth Scopes — Governance Reference

> **TL;DR**: Scopes are the **capability ceiling** — they gate which API endpoints a token can call. UC grants are the **actual authorization** — they determine what data within those endpoints the token can access. Both layers are required for true least-privilege access. There are 36 workspace-level and 9 account-level granular scopes, plus a small set of identity and catch-all scopes.

---

## The Governance Principle

OAuth scopes and UC grants serve different functions. Neither replaces the other.

| Layer | Question it answers | Granularity | Example |
|---|---|---|---|
| **OAuth scopes** | Can this token call this API endpoint? | Per-product-area (e.g., `sql`, `genie`, `unity-catalog`) | Token with `sql` scope can call Statement Execution API |
| **UC grants** | Can this identity access this data? | Per-object (table, function, connection) | `GRANT SELECT ON TABLE` to a specific SP |

A token with `sql` scope but no `GRANT SELECT` → API call succeeds, query returns 0 rows.
A token without `sql` scope but with `GRANT SELECT` → API call fails with 403.

---

## Identity and Catch-All Scopes

Before the 45 granular product scopes, three smaller scope families cover identity and broad access.

### OIDC identity scopes

Standard OpenID Connect scopes, issued as part of any Databricks OAuth flow.

| Scope | What it grants | Notes |
|---|---|---|
| `openid` | OIDC identity token issuance | Required for any OAuth flow |
| `email` | Email claim in the identity token | Needed for apps that key access control off the user's email |
| `profile` | Display name, preferred username claims | Informational |
| `offline_access` | Refresh token issuance | Without this, the user must re-authenticate whenever the access token expires |

### Meta / IAM scopes

Broad-access and identity-management scopes.

| Scope | What it grants | Notes |
|---|---|---|
| `all-apis` | Catch-all for all Databricks REST APIs | Broadest scope. Not a strict superset of the granular scopes — some features also check their specific scope, so pair `all-apis` with the relevant granular scope when in doubt |
| `dashboards.genie` | Genie space access (UI + API) | On Azure, pair with `genie` |
| `iam.current-user:read` | `GET /api/2.0/preview/scim/v2/Me` | Identity verification only |
| `iam.access-control:read` | Read access control lists | Rarely needed by apps |

---

## Account vs. Workspace Tokens: It's the Endpoint, Not the Scope

Databricks does not have a separate "account console–only" OAuth scope. Account vs. workspace access is determined by which OAuth endpoint issued the token, not by a different scope name.

| Token type | Authorize / token endpoint | Audience |
|---|---|---|
| **Account-level** | `https://accounts.cloud.databricks.com/oidc/accounts/<account-id>/v1/{authorize,token}` (Azure: `accounts.azuredatabricks.net`) | Account APIs |
| **Workspace-level** | `https://<workspace-host>/oidc/v1/{authorize,token}` | Workspace APIs |

The same scope strings (`all-apis`, `offline_access`, and the granular product scopes below) apply at both levels — the token's audience determines whether it can call account or workspace APIs.

```bash
# Account-level M2M token
curl -X POST "https://accounts.cloud.databricks.com/oidc/accounts/<account-id>/v1/token" \
  -d "grant_type=client_credentials&client_id=<client-id>&client_secret=<secret>&scope=all-apis"

# Workspace-level M2M token
curl -X POST "https://<workspace-host>/oidc/v1/token" \
  -d "grant_type=client_credentials&client_id=<client-id>&client_secret=<secret>&scope=all-apis"
```

---

## Workspace-Level Granular Scopes (36)

Source: [Workspace API Scopes](https://docs.databricks.com/api/workspace/api/scopes)

Each scope gates a specific product area. The scope string is what you pass in OAuth requests.

| # | Category | Scope string | What it grants | Ops |
|---|---|---|---|---|
| 1 | Access Management | `access-management` | Manage users, service principals, groups, permissions | 7 |
| 2 | AI/BI | `dashboards` | Manage AI/BI Dashboards (Lakeview) | 19 |
| 3 | Alerts | `alerts` | Manage Databricks SQL alerts and alert destinations | 5 |
| 4 | Apps | `apps` | Build and manage custom Databricks Apps | 16 |
| 5 | Authentication | `authentication` | Manage auth settings and configurations | 13 |
| 6 | Clean Rooms | `cleanrooms` | Manage clean rooms, assets, and task runs | 20 |
| 7 | Clusters | `clusters` | Create and manage clusters for data processing and analytics | 35 |
| 8 | Command Execution | `command-execution` | Execute commands/code on clusters and manage execution contexts | 6 |
| 9 | Data Classification | `dataclassification` | Manage data classification for UC catalogs | 4 |
| 10 | Data Quality Monitoring | `dataquality` | Manage Data Quality Monitoring on UC objects | 11 |
| 11 | Databricks SQL | `sql` | Manage SQL warehouses, dashboards, queries, query history, alerts | 52 |
| 12 | Databricks Workspace | `workspace` | Manage notebooks, Git checkouts, and secrets | 24 |
| 13 | Delta Sharing | `sharing` | Configure data sharing with UC — providers, recipients, shares | 27 |
| 14 | File Management | `files` | Manage files on Databricks (filesystem-like interface) | 18 |
| 15 | Genie | `genie` | Manage Genie conversational analytics spaces and queries | 17 |
| 16 | Global Init Scripts | `global-init-scripts` | Manage global initialization scripts | 5 |
| 17 | Identity | `identity` | Manage identities in accounts and workspaces | 4 |
| 18 | Instance Pools | `instance-pools` | Manage instance pools (reduce cluster start/scale-up times) | 9 |
| 19 | Jobs and Workflows | `jobs` | Run and schedule automated jobs on workspaces | 23 |
| 20 | Knowledge Assistants | `knowledge-assistants` | Create and manage Knowledge Assistants and resources | 11 |
| 21 | Libraries | `libraries` | Manage libraries on Databricks | 4 |
| 22 | Marketplace | `marketplace` | Manage ML models, notebooks, apps in the open marketplace | 50 |
| 23 | MLflow | `mlflow` | Manage MLflow experiments, runs, models, and model registry | 75 |
| 24 | Model Serving | `model-serving` | Deploy and manage model serving endpoints (real-time inference) | 20 |
| 25 | Networking | `networking` | Manage network connectivity, private access, network policies | 6 |
| 26 | Notifications | `notifications` | Manage notification destinations for alerts and system notifications | 5 |
| 27 | Pipelines | `pipelines` | Manage pipelines, runs, and Delta Live Table resources | 15 |
| 28 | Lakebase | `postgres` | Create/manage Lakebase projects, branches, and computes. Database access itself uses separate OAuth tokens (see Scope Gotchas below) | 33 |
| 29 | Quality Monitor | `qualitymonitor` | Manage quality monitors on UC objects | 5 |
| 30 | Query History | `query-history` | Manage query history | 1 |
| 31 | SCIM | `scim` | Manage users, SPs, groups, permissions via SCIM protocol | 19 |
| 32 | Secrets Management | `secrets` | Manage secrets for secure credential storage | 11 |
| 33 | Settings | `settings` | Manage security settings for workspaces | 35 |
| 34 | Tags | `tags` | Manage tag policies and tag assignments on workspace objects | 10 |
| 35 | Unity Catalog | `unity-catalog` | Data governance — metastores, catalogs, schemas, tables, external locations, storage credentials | 121 |
| 36 | Vector Search | `vector-search` | Create and query Vector Search indexes | 17 |

---

## Account-Level Granular Scopes (9)

Source: [Account API Scopes](https://docs.databricks.com/api/account/api/scopes)

Account-level scopes are used with account-level tokens (issued via the accounts OIDC endpoint). They control account-wide operations — billing, provisioning, networking, and identity management across all workspaces.

| # | Category | Scope string | What it grants | Ops |
|---|---|---|---|---|
| 1 | Access Management | `access-management` | Manage users, service principals, groups, permissions across the account | 7 |
| 2 | Authentication | `authentication` | Manage auth settings and configurations for the account | 24 |
| 3 | Billing | `billing` | Configure billing and usage aspects of the Databricks account | 7 |
| 4 | Identity | `identity` | Manage identities across the account | 4 |
| 5 | Networking | `networking` | Manage network connectivity, private access, network policies at account level | 22 |
| 6 | Provisioning | `provisioning` | Manage workspace deployment, cross-account IAM roles, storage, encryption | 5 |
| 7 | SCIM | `scim` | Manage users, SPs, groups, permissions via SCIM protocol at account level | 18 |
| 8 | Settings | `settings` | Manage security settings for the account | 6 |
| 9 | Unity Catalog | `unity-catalog` | Configure UC governance at account level — metastores, catalogs, external locations | 15 |

### Shared vs. account-only scopes

Some scope strings appear at both workspace and account level (same string, different endpoint and different operation count):

| Scope | Workspace ops | Account ops | Notes |
|---|---|---|---|
| `access-management` | 7 | 7 | Permissions — workspace-level vs. account-level |
| `authentication` | 13 | 24 | Account level covers more auth settings (OAuth integrations, federation) |
| `identity` | 4 | 4 | CRUD on users/SPs/groups |
| `networking` | 6 | 22 | Account level covers far more networking config (VPCs, private endpoints, etc.) |
| `scim` | 19 | 18 | Same SCIM protocol, different scope |
| `settings` | 35 | 6 | Workspace level exposes more granular settings |
| `unity-catalog` | 121 | 15 | Account level: metastore management, cross-workspace governance |

Two scopes are account-only, with no workspace equivalent: `billing` (DBU usage, budgets, cost management) and `provisioning` (workspace creation/deletion, storage config, IAM roles).

---

## AI App Scope Selection

For Databricks AI apps, most of the 45 granular scopes are irrelevant. Here's what matters:

| Use case | Scopes needed |
|---|---|
| Identity-only MCP (M2M for all data) | `openid email profile offline_access` — no product scopes needed |
| Genie OBO | + `dashboards.genie` + `genie` |
| Agent Bricks / Model Serving OBO | + `model-serving` (UI name: `serving.serving-endpoints`) |
| External MCP (UC HTTP) | + `unity-catalog` |
| Direct SQL OBO (via UI User Authorization) | + `sql` — `current_user()` resolves to the human's email |
| Claude Code external client | `all-apis offline_access` (U2M PKCE) |
| Lakebase (management API) | + `postgres` (database access itself uses separate credential tokens) |
| Full-featured app | All of the above + `all-apis` |

**Principle**: Request only what the app needs. `all-apis` is convenient but grants access to every API endpoint.

### UI User Authorization scopes

The Account Console's User Authorization picker exposes a curated set of scopes that produce real on-behalf-of (OBO) JWTs with effective scopes, distinct from configuring scopes via the CLI alone:

| UI scope name | CLI scope equivalent | Purpose |
|---|---|---|
| `sql` | `sql` | Statement Execution API — OBO SQL with `current_user()` = human |
| `dashboards.genie` | `dashboards.genie` | Genie space access |
| `files.files` | `files` | File management operations |
| `serving.serving-endpoints` | `model-serving` | Model Serving / Agent Bricks OBO |
| `vectorsearch.vector-search-indexes` | `vector-search` | Vector Search index queries |
| `catalog.connections` | `unity-catalog` (partial) | UC connection access (External MCP) |
| `catalog.catalogs:read` | `unity-catalog` (partial) | Read catalog metadata |
| `catalog.schemas:read` | `unity-catalog` (partial) | Read schema metadata |
| `catalog.tables:read` | `unity-catalog` (partial) | Read table metadata |

> The External MCP proxy (`/api/2.0/mcp/external/{conn}`) checks the `unity-catalog` scope to verify `USE CONNECTION` privilege, separately from the granular `catalog.*` scopes above. Add `unity-catalog` to your scope set when using External MCP connections.

### Full scope set for a multi-service app

```bash
databricks account custom-app-integration update '<integration-id>' \
  --profile <account-profile> \
  --json '{
    "scopes": [
      "offline_access", "email", "iam.current-user:read",
      "openid", "dashboards.genie", "genie",
      "iam.access-control:read", "profile",
      "model-serving", "sql", "all-apis", "unity-catalog"
    ],
    "user_authorized_scopes": [
      "dashboards.genie", "genie", "model-serving",
      "sql", "all-apis", "unity-catalog"
    ]
  }'
```

**Add all scopes upfront.** Extra scopes are harmless but missing ones cause hard-to-diagnose 403 errors.

---

## Write-Risk Classification (Blast-Radius Tiers)

Every scope except `query-history` allows mutations. There are no read-only scope variants (e.g., no `sql:read` vs `sql:write`) — the same scope string gates create, update, and delete. This makes scope selection a **blunt instrument** for least-privilege access (LPA) — but still valuable as a second fence beyond UC grants.

| Tier | Scopes | Why they matter |
|---|---|---|
| **Tier 1 — Critical** | `unity-catalog`, `sql`, `clusters`, `workspace`, `secrets`, `settings`, `authentication`, `provisioning` | Destructive DDL, arbitrary SQL execution, compute and code control, credential storage, security-posture changes, workspace lifecycle (account-level) |
| **Tier 2 — High** | `jobs`, `pipelines`, `apps`, `sharing`, `files`, `model-serving`, `scim`, `postgres`, `networking` | Arbitrary code execution via job tasks, data sharing to external recipients, app deployment, identity/group manipulation, Lakebase infrastructure lifecycle |
| **Tier 3 — Medium** | `mlflow`, `dashboards`, `genie`, `vector-search`, `alerts`, `cleanrooms`, `instance-pools`, `global-init-scripts`, `libraries`, `marketplace`, `tags`, `knowledge-assistants` | Limited blast radius per scope; still capable of resource creation/deletion within its product area |
| **Tier 4 — Low** | `query-history` (read-only), `access-management`, `identity`, `dataclassification`, `dataquality`, `qualitymonitor`, `notifications`, `billing`, `command-execution` | Read-heavy, or writes constrained to a narrow configuration surface |

### LPA recommendation for AI app service principals

Replace `all-apis` with the union of only the granular scopes each service principal actually needs:

| App component | Purpose | Recommended scopes | What's excluded by not granting `all-apis` |
|---|---|---|---|
| Frontend app using Genie OBO | Genie queries, Vector Search read, Foundation Model API | `genie`, `model-serving` | Cluster creation, job creation, UC mutation, secrets access, app deployment |
| Custom MCP server | SQL read/write, UC queries | `sql` | Cluster creation, pipeline management, notebook export, auth configuration |
| External MCP client | UC HTTP connections | `unity-catalog` | SQL execution, cluster management, app deployment, job creation |
| Agent Bricks integration | Model serving, MLflow | `model-serving`, `mlflow` | Direct SQL access, cluster management, workspace configuration |
| Account-level automation | Billing and provisioning ops | `billing`, `provisioning`, `settings` | Any data or workload access |

**Key principle**: The write operations you exclude are the ones that would let a compromised token do lateral damage beyond its intended purpose.

### What scope-based LPA does not cover

OAuth scopes gate which API endpoints a token can call. They do not gate:
- **What data** the token can read/write within that scope — that's UC grants
- **Which tables** SQL can touch — that's UC row filters / column masks
- **Which resources** within a scope — e.g., `sql` scope covers all warehouses, not just one

Full least-privilege access needs both layers: granular OAuth scopes (API-level) plus granular UC grants (data-level).

---

## SQL Identity Functions

These Databricks SQL functions determine identity in row filters, column masks, and RLS policies. Understanding which identity each function resolves is important for correct access control.

| Function | Returns | Evaluates | SP behavior | Since |
|---|---|---|---|---|
| `session_user()` | Connected user | The user who established the session | SP UUID | Runtime 14.1 (recommended) |
| `current_user()` | Executing user | The user executing the statement | SP UUID for M2M; human email for OBO | Runtime 10.4 |
| `user()` | Executing user | Alias for `current_user()` | SP UUID | Runtime 13.3 |
| `is_member(group)` | Boolean | Whether `session_user` is in a workspace-local or account group assigned to the workspace | SP's groups | All |
| `is_account_group_member(group)` | Boolean | Whether `session_user` is in an account-level group | SP's groups | UC only |

Since Runtime 14.1, Databricks recommends `session_user()` over `current_user()` or `user()`, since the SQL standard differentiates between the two.

**Genie OBO gotcha**: Under Genie OBO, `current_user()` returns the human's email correctly, but `is_member()` checks `session_user`'s groups — which resolves to the Genie service context rather than the human's workspace groups. `is_member('executives')` in a row filter will not reflect the human's actual group membership in this flow.

**Recommended pattern**: use `current_user()` with an allowlist table lookup instead of `is_member()` when the policy needs to apply under Genie OBO:

```sql
-- Does not reflect the human's group membership under Genie OBO:
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(is_member('executives'), val, NULL);

-- Recommended — resolves the human identity directly:
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(current_user() IN (SELECT email FROM quota_viewers), val, NULL);
```

### Lakebase (Postgres) equivalents

Lakebase uses Postgres-native functions rather than Databricks SQL functions:

| Databricks SQL | Lakebase (Postgres) | Notes |
|---|---|---|
| `current_user()` / `session_user()` | `current_user` | Returns the Databricks identity (e.g., a workspace email). In Data API context, this is the assumed role |
| `is_member(group)` | `pg_has_role(current_user, 'role', 'member')` | Postgres-native role membership check |
| UC row filters | `CREATE POLICY ... USING (...)` | Postgres RLS — functionally equivalent |
| UC column masks | No direct equivalent | Use views or RLS policies for column-level control |

**References**: [session_user](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/session_user) | [current_user](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/current_user) | [is_member](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/is_member) | [is_account_group_member](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/is_account_group_member)

---

## Scope Gotchas

| Issue | Governance impact |
|---|---|
| `sql` scope: CLI vs. UI | Adding `sql` via CLI `custom-app-integration update` alone does not produce a real OBO JWT — the token remains a minimal OIDC identity token. UI-driven User Authorization (the consent flow in the Account Console or app login) produces a real OBO JWT: `X-Forwarded-Access-Token` carries the `sql` scope, and `current_user()` in a SQL warehouse returns the human user's email. Use the UI path for true OBO SQL. |
| `genie` scope hidden on Azure | The Account Console UI does not list `genie` as an available scope, but the Genie Conversation API requires it on Azure. Add it via CLI/API. |
| `unity-catalog` scope for External MCP | Required by the External MCP proxy to verify `USE CONNECTION` privilege. Add it when wiring External MCP connections — a missing scope returns a 403 with `required scopes: unity-catalog`. |
| Scope changes require re-auth | Adding scopes to an existing OAuth integration does not propagate to existing refresh tokens. Users need to re-authorize for the new scopes to take effect. |
| `all-apis` is not a superset | `all-apis` covers REST APIs broadly, but some features also check their specific scope. Include both `all-apis` and the granular scope when in doubt. |
| `postgres` = Lakebase management only | The `postgres` scope gates Lakebase platform management (projects, branches, computes). Database access itself uses a separate auth flow: generate a 1-hour OAuth token via `databricks postgres generate-database-credential` (CLI) or `w.postgres.generate_database_credential()` (SDK), or use a native Postgres password for apps that can't do hourly token rotation — see [Lakebase Authentication](https://learn.microsoft.com/en-us/azure/databricks/oltp/projects/authentication). |
| Account vs. workspace: same scopes | There is no account-only scope string. The same scope strings work at both levels — the token endpoint determines the audience. |
| `dashboards` vs. `dashboards.genie` | `dashboards` manages AI/BI Dashboard CRUD. `dashboards.genie` accesses Genie spaces within dashboards. Different scopes for different operations. |
| `scim` vs. `access-management` vs. `identity` | Three overlapping scopes for identity management. `scim` covers SCIM protocol endpoints, `access-management` covers permissions, `identity` covers core identity CRUD. Most apps need none of these. |

---

## Related

- [Authorization](authorization.md) — Token patterns and scope vs. UC grant interplay
- [Proxy Architecture](proxy-architecture.md) — How scopes flow through the Apps proxy
