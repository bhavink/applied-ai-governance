# Databricks OAuth Scopes — Complete Reference

> **TL;DR**: Three categories — (1) OIDC identity scopes (`openid`, `email`, `profile`, `offline_access`), (2) Meta/IAM scopes (`all-apis`, `dashboards.genie`, `iam.*`), (3) Granular product scopes (36 workspace + 9 account). Scopes are the **capability ceiling** — they gate which API endpoints a token can call. UC grants are the **actual authorization** — they determine what data within those endpoints the token can access. Both layers are required for true least-privilege access.

---

## Account vs Workspace Tokens

There is no separate "account console–only" OAuth scope. Databricks distinguishes account vs workspace tokens by which OAuth **endpoints** you use, not by different scope names.

| Token type | Authorize endpoint | Token endpoint |
|---|---|---|
| **Account-level** | `https://accounts.cloud.databricks.com/oidc/accounts/<account-id>/v1/authorize` | `https://accounts.cloud.databricks.com/oidc/accounts/<account-id>/v1/token` |
| **Workspace-level** | `https://<workspace-host>/oidc/v1/authorize` | `https://<workspace-host>/oidc/v1/token` |

> **Azure variant**: Account host is `accounts.azuredatabricks.net` instead of `accounts.cloud.databricks.com`.

The same scope strings (`all-apis`, `offline_access`, granular product scopes) apply in both cases. The token's **audience** — determined by which endpoint issued it — controls whether it can call account or workspace APIs.

```bash
# Account-level M2M token
curl -X POST "https://accounts.cloud.databricks.com/oidc/accounts/<acct-id>/v1/token" \
  -d "grant_type=client_credentials&client_id=<sp-uuid>&client_secret=<secret>&scope=all-apis"

# Workspace-level M2M token
curl -X POST "https://<workspace-host>/oidc/v1/token" \
  -d "grant_type=client_credentials&client_id=<sp-uuid>&client_secret=<secret>&scope=all-apis"
```

---

## OIDC Identity Scopes

Standard OpenID Connect scopes. Not surfaced in `user_authorized_scopes` — platform-managed.

| Scope | What it grants | Notes |
|---|---|---|
| `openid` | OIDC identity token issuance | Required for any OAuth flow |
| `email` | Email claim in identity token | Without this, proxy may not set `X-Forwarded-Email` |
| `profile` | Display name, preferred username claims | Informational |
| `offline_access` | Refresh token issuance | Without this, user must re-authenticate when access token expires |

---

## Meta / IAM Scopes

Broad-access and identity management scopes. Not on the API Scopes page but referenced across docs.

| Scope | What it grants | Notes |
|---|---|---|
| `all-apis` | Catch-all for all Databricks REST APIs | Broadest scope available. **Not a true superset** of granular scopes — some features also check their specific scope. Use granular scopes when possible. |
| `dashboards.genie` | Genie space access (UI + API) | Must be paired with `genie` on Azure |
| `iam.current-user:read` | `GET /api/2.0/preview/scim/v2/Me` | Identity verification only |
| `iam.access-control:read` | Read access control lists | Rarely needed by apps |

---

## Workspace-Level Granular Scopes (36)

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
| 28 | Lakebase | `postgres` | Create projects/branches/computes, manage configurations. **Database access uses separate OAuth tokens** via `generate-database-credential`. | 33 |
| 29 | Quality Monitor | `qualitymonitor` | Manage quality monitors on UC objects | 5 |
| 30 | Query History | `query-history` | Manage query history | 1 |
| 31 | SCIM | `scim` | Manage users, SPs, groups, permissions via SCIM protocol | 19 |
| 32 | Secrets Management | `secrets` | Manage secrets for secure credential storage | 11 |
| 33 | Settings | `settings` | Manage security settings for workspaces | 35 |
| 34 | Tags | `tags` | Manage tag policies and tag assignments on workspace objects | 10 |
| 35 | Unity Catalog | `unity-catalog` | Data governance — metastores, catalogs, schemas, tables, external locations, storage credentials | 121 |
| 36 | Vector Search | `vector-search` | Create and query Vector Search indexes | 17 |

> **`postgres` = Lakebase.** The `postgres` scope controls Lakebase **platform management** (create/delete projects, branches, computes). **Database access** is a separate auth layer: generate a 1-hour OAuth token via `databricks postgres generate-database-credential` (CLI) or `w.postgres.generate_database_credential()` (SDK), then use it as a Postgres password. Lakebase also supports native Postgres passwords for apps that cannot do hourly token rotation.

---

## Account-Level Granular Scopes (9)

Account-level scopes are used with account-level tokens (issued via the accounts OIDC endpoint). They control access to account-wide operations — billing, provisioning, networking, identity management across all workspaces.

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

### Shared vs account-only scopes

Some scope strings appear at both workspace and account level (same string, different endpoint):

| Scope | Workspace ops | Account ops | Notes |
|---|---|---|---|
| `access-management` | 7 | 7 | Permissions — workspace-level vs account-level |
| `authentication` | 13 | 24 | More account-level auth settings (OAuth integrations, federation) |
| `identity` | 4 | 4 | CRUD on users/SPs/groups |
| `networking` | 6 | 22 | Account has far more networking config (VPCs, private endpoints, etc.) |
| `scim` | 19 | 18 | Same SCIM protocol, different scope |
| `settings` | 35 | 6 | Workspace has more granular settings |
| `unity-catalog` | 121 | 15 | Account-level: metastore management, cross-workspace governance |

Account-only scopes (no workspace equivalent):

| Scope | Purpose |
|---|---|
| `billing` | DBU usage, budgets, cost management |
| `provisioning` | Workspace creation/deletion, storage config, IAM roles |

---

## AI App Scope Selection

For Databricks AI apps, most of the 36 granular scopes are irrelevant. Here is what matters:

| Use case | Scopes needed |
|---|---|
| **Identity-only MCP** (M2M for all data) | `openid email profile offline_access` |
| **Genie OBO** | + `dashboards.genie` + `genie` |
| **Agent Bricks / Model Serving OBO** | + `model-serving` (UI name: `serving.serving-endpoints`) |
| **External MCP (UC HTTP connections)** | + `unity-catalog` |
| **Direct SQL OBO** (via UI User Authorization) | + `sql` — produces real OBO JWT; `current_user()` = human email |
| **Full-featured app** | All above + `all-apis` |
| **Claude Code external client** | `all-apis offline_access` (U2M PKCE) |
| **Lakebase (management API)** | + `postgres` (database access uses separate `generate-database-credential` tokens) |

### Full scope set CLI command

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

> **Add all scopes upfront.** Extra scopes are harmless; missing ones cause cryptic 403 errors.

---

## Write-Risk Classification (LPA)

Every scope except `query-history` allows mutations. Scope descriptions say "Manage" / "Create" / "Configure" — meaning create, update, and delete operations all live behind the same scope string. There is no read-only variant of any scope (no `sql:read` vs `sql:write`).

This makes scope selection a blunt instrument for least-privilege access — but still valuable as a second fence beyond UC grants.

### Tier 1 — Critical (infrastructure destruction / data loss)

| Scope | Write risk |
|---|---|
| `unity-catalog` | DROP catalog/schema/table, revoke grants, delete external locations, delete storage credentials. 121 ops including destructive DDL. A compromised token can drop production tables. |
| `sql` | Create/delete warehouses, execute arbitrary SQL (INSERT/UPDATE/DELETE/DROP). Statement Execution API = full SQL. This is data-plane write access. |
| `clusters` | Create/terminate/delete clusters, edit cluster policies. Compute cost explosion + data access (cluster = execution context). |
| `workspace` | Delete notebooks, import malicious code, manage secrets. Code exfiltration and injection. |
| `secrets` | Create/delete secret scopes, put/delete secrets. Direct credential theft and injection. |
| `settings` | Modify security settings, token policies, workspace config. Can weaken security posture (disable IP restrictions, etc.). |
| `authentication` | Manage OAuth integrations, federation configs. Can create backdoor OAuth apps or modify token policies. |
| `provisioning` | Create/delete workspaces, modify storage config. Account-level only. Can destroy entire workspaces. |

### Tier 2 — High (operational disruption / data exposure)

| Scope | Write risk |
|---|---|
| `jobs` | Create/run/delete jobs, cancel runs. Can run arbitrary code via job tasks. Cost + data access. |
| `pipelines` | Create/delete pipelines, start/stop runs. DLT pipeline manipulation. |
| `apps` | Create/deploy/delete Databricks Apps. Can deploy malicious apps with their own service principals. |
| `sharing` | Create shares, add/remove recipients, grant external access. Data exfiltration — share production tables to external recipients. |
| `files` | Upload/delete files, create directories. Can inject malicious files, delete data files. |
| `model-serving` | Create/delete serving endpoints, update traffic config. Can take down inference endpoints or route traffic to malicious models. |
| `scim` | Create/delete users, SPs, modify group membership. Identity manipulation — add attacker SP to admin groups. |
| `postgres` | Create/delete Lakebase projects, branches, computes. Note: database read/write uses separate OAuth tokens via `generate-database-credential`. |
| `networking` | Create/delete private endpoints, modify network policies. Can open network paths or cut connectivity. |

### Tier 3 — Medium (limited blast radius)

| Scope | Write risk |
|---|---|
| `mlflow` | Create/delete experiments, runs, registered models |
| `dashboards` | Create/delete AI/BI dashboards |
| `genie` | Create/manage Genie spaces |
| `vector-search` | Create/delete VS indexes and endpoints |
| `alerts` | Create/delete SQL alerts |
| `cleanrooms` | Create/delete clean rooms |
| `instance-pools` | Create/delete instance pools |
| `global-init-scripts` | Create/delete init scripts (code injection risk) |
| `libraries` | Install/uninstall libraries on clusters |
| `marketplace` | Publish/manage marketplace listings |
| `tags` | Create/modify/delete tags and tag policies |
| `knowledge-assistants` | Create/delete Knowledge Assistants |

### Tier 4 — Low (read-heavy, minimal write)

| Scope | Write risk |
|---|---|
| `query-history` | **Read-only** (1 operation: list query history) |
| `access-management` | Set/update permissions (controlled writes) |
| `identity` | CRUD on users/SPs (4 operations) |
| `dataclassification` | Manage classification rules |
| `dataquality` | Manage quality monitors |
| `qualitymonitor` | Manage quality monitors |
| `notifications` | Manage notification destinations |
| `billing` | Account-level billing config (read-heavy) |
| `command-execution` | Execute commands on clusters (requires cluster access too) |

### LPA recommendations for AI app service principals

| SP | Purpose | Recommended scopes | Blocked without `all-apis` |
|---|---|---|---|
| **SP-A** (Streamlit frontend) | Genie OBO, VS read, FM API | `genie`, `model-serving` | Can't create clusters, jobs, modify UC, access secrets, deploy apps |
| **SP-B** (Custom MCP) | SQL read/write, UC queries | `sql` | Can't create clusters, manage pipelines, export notebooks, modify auth |
| **SP-C** (External MCP client) | UC HTTP connections | `unity-catalog` | Can't do SQL, manage clusters, deploy apps, create jobs |
| **SP-D** (Agent Bricks) | Model serving, MLflow | `model-serving`, `mlflow` | Can't access SQL directly, manage clusters, modify workspace |
| **Admin automation** | Account ops | `billing`, `provisioning`, `settings` | Can't touch data or workloads at all |

> **Key principle**: Replace `all-apis` with only the granular scopes each SP actually needs. The write operations you block are the ones that would let a compromised token do lateral damage beyond its intended purpose.

### What LPA does NOT protect against

OAuth scopes gate which API endpoints a token can call. They do not gate:

- **What data** the token can read/write within a scope — that is UC grants
- **Which tables** SQL can touch — that is UC row filters and column masks
- **Which resources** within a scope — `sql` scope means access to all warehouses, not just one

True least-privilege requires both layers: granular OAuth scopes (API-level) + granular UC grants (data-level).

---

## SQL Identity Functions Reference

These Databricks SQL functions determine identity in row filters, column masks, and RLS policies. Understanding which identity each function resolves is critical for correct access control.

| Function | Returns | Evaluates | SP behavior | Since |
|---|---|---|---|---|
| `session_user()` | Connected user | The user who established the session | SP UUID | Runtime 14.1 (**recommended**) |
| `current_user()` | Executing user | The user executing the statement | SP UUID | Runtime 10.4 |
| `user()` | Executing user | Alias for `current_user()` | SP UUID | Runtime 13.3 |
| `is_member(group)` | Boolean | Whether **session_user** is in group (workspace-local or account groups assigned to workspace) | SP's groups | All |
| `is_account_group_member(group)` | Boolean | Whether **session_user** is in account-level group | SP's groups | UC only |

> Since Runtime 14.1, Databricks recommends `session_user()` over `current_user()` or `user()`. The SQL standard differentiates between the two.

### GAP 4 — Genie OBO and `is_member()`

Under Genie OBO, `current_user()` returns the human's email (correct), but `is_member()` checks `session_user`'s groups — which resolves to the Genie service context, **not** the human's workspace groups. This is why `is_member('executives')` in a row filter fails silently under Genie OBO.

**Broken pattern:**

```sql
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(is_member('executives'), val, NULL);
```

**Correct pattern — use `current_user()` with an allowlist table:**

```sql
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(current_user() IN (SELECT email FROM quota_viewers), val, NULL);
```

---

## Gotchas

| Issue | Detail |
|---|---|
| `sql` scope: CLI vs UI | Adding `sql` via CLI `custom-app-integration update` does NOT cause the JWT `scope` claim to include it. Setting `sql` via UI User Authorization (Public Preview) DOES produce a real OBO JWT with `sql` in the scope claim and `current_user()` = human email. Use the UI method for true OBO SQL, or fall back to M2M. |
| `genie` scope hidden on Azure | The account console UI does not show `genie` as an available scope, but the Genie Conversation API requires it on Azure. Add it via CLI/API. |
| `unity-catalog` scope undocumented | Required by the External MCP proxy to verify `USE CONNECTION` privilege. Not in official docs. Missing = `403: "does not have required scopes: unity-catalog"`. |
| Scope changes require re-auth | Adding scopes to an existing OAuth integration does not propagate to existing refresh tokens. Users must re-authorize (delete SP, recreate, re-grant UC). |
| `all-apis` is not a superset | `all-apis` covers REST APIs broadly but some features also check their specific scope. When in doubt, include both `all-apis` AND the granular scope. |
| `postgres` = Lakebase management only | The `postgres` scope gates Lakebase platform management (projects, branches, computes). Database access is separate — uses OAuth tokens generated via `generate-database-credential` (1hr lifetime) or native Postgres passwords. Two distinct auth layers. |
| Account vs workspace: same scope strings | There is no "account-only" scope. Same scope strings work for both. The token endpoint determines the audience. |
| `dashboards` vs `dashboards.genie` | `dashboards` = manage AI/BI Dashboard CRUD. `dashboards.genie` = access Genie spaces within dashboards. Different scopes for different operations. |
| `scim` vs `access-management` vs `identity` | Three overlapping scopes for identity management. `scim` = SCIM protocol endpoints. `access-management` = permissions. `identity` = core identity CRUD. Most apps need none of these. |
