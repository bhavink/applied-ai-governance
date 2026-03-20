# Custom MCP Architecture — Governance, Security, Observability

## Principles

1. **MCP is the single gateway** — apps never call Databricks APIs directly. All data/compute access routes through MCP tools.
2. **Scopes over grants** — OAuth scopes restrict what a token can do. Direct table/service grants are minimized; UC governance (row filters, column masks, `USE CONNECTION`, `EXECUTE`) enforces fine-grained access.
3. **UC governance end-to-end** — every tool invocation runs under the caller's identity. Row filters, column masks, and connection access checks fire at the engine level.
4. **100% trace coverage** — every tool call creates an MLflow trace with: service, tool, caller, request_id, latency, status.
5. **100% audit coverage** — every tool call writes to the audit table (async, fire-and-forget). Denials, errors, and successes all recorded.
6. **Defense in depth** — tool-level RBAC (federation) + UC governance + scope restrictions. Multiple layers, any one sufficient.
7. **No secrets in code** — UC connections hold external credentials. GitHub token comes from `USE CONNECTION`, not env vars.

## Two Identity Patterns

### mcp-databricks-federation (External IDP → Role SPs)

```
External User → IDP (Auth0/Okta/Entra) → App Server (JWT verify)
  → Token Exchange (RFC 8693) → Databricks SP token (scoped)
  → MCP Server → Tools → UC Governance (fires per SP group)
```

**Scopes on exchanged token**: `sql genie serving`
- `sql` → SQL warehouse access (row filters, column masks fire)
- `genie` → Genie Conversation API
- `serving` → Model Serving endpoints (supervisor agent)

**UC governance layers**:
- Row filters: `is_member('authz_showcase_west')` etc.
- Column masks: `margin_pct` masked for non-finance/exec/admin
- `USE CONNECTION`: controls GitHub/external API access per SP
- `EXECUTE`: controls UC function access per SP
- `CAN QUERY`: controls serving endpoint access per SP

### mcp-databricks-obo (Databricks Native Identity)

```
Databricks User → OAuth (browser) → Apps Proxy
  → x-forwarded-access-token (OBO token, scoped)
  → MCP Server → Tools → UC Governance (fires per user identity)
```

**Scopes on OBO token** (configured in App UI → User Authorization):
- `sql` → SQL warehouse
- `dashboards.genie` + `genie` → Genie (Azure needs both)
- `serving` → Model Serving endpoints
- `apps` → calling other Databricks Apps

**UC governance**: fires as `current_user()` = human email. No SP intermediary.

## Scope-Based Access Model

| Resource | Scope Required | UC Grant Required | Who Checks |
|----------|---------------|-------------------|------------|
| SQL Warehouse | `sql` | `CAN USE` on warehouse | Token + UC |
| Genie Space | `genie` + `dashboards.genie` | Access to space + underlying tables | Token + UC |
| Model Serving | `serving` | `CAN QUERY` on endpoint | Token + UC |
| Vector Search | `sql` (SDK uses SQL internally) | `SELECT` on VS index | Token + UC |
| UC Connection | `sql` (for DESCRIBE CONNECTION) | `USE CONNECTION` | Token + UC |
| UC Function | `sql` (for SELECT fn()) | `EXECUTE` on function | Token + UC |
| Audit Table | `sql` | `SELECT` on table | Token + UC |

**Key insight**: Scopes restrict what the token CAN do. UC grants restrict what the identity CAN access. Both layers enforce independently. Revoking either blocks access.

## External Credentials via UC Connections

**Never store external secrets in env vars or code.** Use UC connections:

```sql
-- Create connection (one-time setup)
CREATE CONNECTION github_bearer_token
  TYPE HTTP
  OPTIONS (host 'https://api.github.com', bearer_token SECRET '<pat>');

-- Control access (per-identity)
GRANT USE CONNECTION ON CONNECTION github_bearer_token TO `<sp-or-group>`;
REVOKE USE CONNECTION ON CONNECTION github_bearer_token FROM `<sp-or-group>`;
```

At runtime, the MCP server:
1. Calls `DESCRIBE CONNECTION` with caller's token → UC checks `USE CONNECTION`
2. If allowed → retrieves connection options (includes credential)
3. Uses credential for the external API call
4. Audit records the UC connection access

## Observability Stack

```
Tool Call → MLflow Trace (spans: auth, sql, external_api, audit)
         → Audit Table (async, never blocks response)
         → Structured JSON Logs (request_id correlation)
         → Lakeview Dashboard (queries audit table)
```

### Audit Table Schema

| Column | Type | Description |
|--------|------|-------------|
| request_id | STRING | Correlation ID (from header or generated) |
| request_time | TIMESTAMP | When the tool call started |
| external_user_email | STRING | Who made the call (from IDP or OBO) |
| role_mapped | STRING | Role (federation) or "obo_user" (OBO) |
| tool_name | STRING | Which tool was called |
| status | STRING | success / error / access_denied |
| error_code | STRING | Error classification |
| latency_ms | INT | End-to-end tool latency |

### MLflow Trace Tags

Every trace includes: `service_name`, `tool`, `caller.email`, `caller.role`, `request_id`, `status`, `latency_ms`

## Rate Limiting

| API | Limit | Strategy |
|-----|-------|----------|
| Genie | 5 QPM per workspace | In-memory sliding window, return 429 with retry_after_ms |
| SQL | No hard limit | Connection pool limits (20 concurrent) |
| Serving | Depends on endpoint | Retry with backoff on 429 |
| GitHub | 5000/hr per token | Retry with backoff on 429 |

## Supervisor Agent Integration

Both MCP servers can be registered as sub-agents of a Databricks Supervisor Agent:

```
Supervisor Agent (Model Serving endpoint)
  → UC Connection (bearer token auth) → Custom MCP Server
  → Genie Space (direct)
  → Knowledge Assistant endpoint (direct)
  → UC Functions (direct)
```

**Registration path**: Create a UC connection pointing to the MCP server URL, then add it as an "External MCP Server" sub-agent in the Supervisor UI.

**Access control lever**: `USE CONNECTION` on the UC connection. Revoking it removes the MCP from the user's supervisor experience at runtime. Max 20 sub-agents per supervisor.

**OBO requirement**: Supervisor uses on-behalf-of authorization — the calling user's identity propagates to sub-agents. This is how per-user permission checks work at runtime.

**Stateful Agents (Lakebase)**:
- Short-term memory: `thread_id` + LangGraph checkpointing in Lakebase
- Long-term memory: cross-session key insights in Lakebase
- Genie conversation threading: `conversation_id` persistence in app state
- Both MCP servers support `conversation_id` on genie_query for multi-turn conversations

## Security Checklist

- [ ] No secrets in env vars (use UC connections)
- [ ] All SQL uses parameterized queries or safe escaping
- [ ] Input validation on all tool parameters
- [ ] Rate limiting on Genie (5 QPM)
- [ ] Connection pool limits prevent resource exhaustion
- [ ] Async audit never blocks tool response
- [ ] Structured logging with request_id for tracing
- [ ] Health check validates all dependencies
- [ ] Retry with jitter prevents thundering herd
- [ ] Token never logged (even in error messages)

---

## IDP Swap Guide -- Changing Identity Providers

The federation architecture is designed so that swapping IDPs (e.g., Auth0 to Okta or Entra) is a configuration change, not a rewrite.

### What changes when swapping IDPs

| Component | Auth0 | Okta | Entra ID |
|---|---|---|---|
| **Token endpoint** | `https://your-tenant.us.auth0.com/oauth/token` | `https://your-org.okta.com/oauth2/{server}/v1/token` | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` |
| **JWKS endpoint** | `.../.well-known/jwks.json` | `.../v1/keys` | `.../discovery/v2.0/keys` |
| **Issuer format** | `https://your-tenant.us.auth0.com/` (trailing slash) | `https://your-org.okta.com/oauth2/{server}` (no slash) | `https://login.microsoftonline.com/{tenant}/v2.0` |
| **M2M sub claim** | `{client_id}@clients` | `{client_id}` | `{app_id}` (GUID) |
| **Claims injection** | Action (post-login trigger) | Authorization Server custom claims | Claims Mapping Policy |
| **Namespace required?** | Yes (must not be provider domain) | No | No |
| **SPA scopes** | `openid profile email` | `openid profile email` + custom | `openid profile email User.Read` |
| **Group format** | Strings (app_metadata) | Strings (groups) | GUIDs (Security Groups) |

### What to update

1. **Claims injection mechanism** -- different config per IDP, same concept (inject groups, role, email into access token)
2. **IDP API / Resource Server** -- register the audience (workspace URL) with the new IDP
3. **M2M App** -- create a confidential client for the token broker
4. **SPA App** -- create a PKCE app for browser login
5. **Federation policy on each SP** -- update `issuer` and `subject` format; `audiences` stays the same (it is the workspace URL)
6. **Token broker function** -- update IDP domain, token endpoint URL, claim extraction paths
7. **Browser app** -- update IDP config, claim namespace

### What does NOT change

- Databricks SPs, groups, UC governance
- MCP server code
- ROLE_SP_MAP (SP app_ids are Databricks-side)
- Token exchange endpoint (`/oidc/v1/token`, same parameters)
- Audit table, dashboard, traces

### Common issuer gotcha

The `issuer` URL must **exactly match** the `iss` claim in the JWT:
- Auth0: `https://your-tenant.us.auth0.com/` (trailing slash required)
- Okta: `https://your-org.okta.com/oauth2/{server}` (no trailing slash)
- Entra: `https://login.microsoftonline.com/{tenant}/v2.0` (v2.0 suffix)

---

## Role-Based Service Principal Architecture

### Why SPs, not individual identities

For external users (channel partners, auditors, consultants), provisioning individual Databricks identities does not scale. Instead, create one **Service Principal per role** and map N external users to O(roles) SPs:

| External Users | Role | Databricks SP |
|---|---|---|
| 50 partner sales reps (West) | west_sales | `fed-sp-west-sales` |
| 50 partner sales reps (East) | east_sales | `fed-sp-east-sales` |
| 10 external auditors | finance | `fed-sp-finance` |
| 5 partner executives | executive | `fed-sp-executive` |

**Key insight**: The SP handles **authorization** (what data you can see). The JWT handles **attribution** (who you are). Together they provide governed access + full audit without provisioning a single Databricks user.

### Federation policy per SP

Each role-SP has a federation policy that binds it to the IDP:

```json
{
  "oidc_policy": {
    "issuer": "https://your-tenant.us.auth0.com/",
    "audiences": ["https://adb-<workspace-id>.azuredatabricks.net"],
    "subject": "<idp-client-id>@clients"
  }
}
```

### Two policy levels

| Level | Scope | When to use |
|---|---|---|
| **SP-Level** | Only the specific SP can exchange | Federation Exchange, per-partner access (tighter blast radius) |
| **Account-Level** | Any identity in the account can exchange | CI/CD (GitHub Actions, GitLab), broad workload identity |

### Subject claim formats by IDP

| IDP | M2M Subject Format | Notes |
|---|---|---|
| Auth0 | `{client_id}@clients` | Trailing `@clients` suffix |
| Okta | `{client_id}` | No suffix |
| Entra ID | `{app_id}` (GUID) | Application (client) ID, not Object ID |
| GitHub Actions | `repo:{org}/{repo}:ref:refs/heads/main` | OIDC subject for workflows |

### Complete grants checklist per role-SP

| # | Grant | On | To | Why |
|---|---|---|---|---|
| 1 | Federation Policy | Each role-SP | -- | JWT to token exchange |
| 2 | CAN_USE | SQL Warehouse | All role-SPs + app SP | Execute SQL |
| 3 | USE CATALOG | Data catalog | All role-SPs + app SP | Catalog access |
| 4 | USE SCHEMA | Data schema(s) | All role-SPs + app SP | Schema access |
| 5 | SELECT | Data tables | All role-SPs | Query data (row filters apply) |
| 6 | SELECT | Vector Search index | App SP | Knowledge base / RAG queries |
| 7 | MODIFY | Audit table | App SP only | Audit writes (role-SPs: zero access) |
| 8 | USE CONNECTION | UC Connection(s) | Privileged SPs only | External API access |
| 9 | CAN_QUERY | Serving endpoint(s) | Privileged SPs only | AI agent / model serving |
| 10 | CAN_RUN | Genie Space | All role-SPs | Natural language SQL |
| 11 | Workspace group membership | Group per role | Each role-SP added | `is_member()` in row filters |

---

## Seven Governance Enforcement Points

Seven enforcement points form the chain from external user to data access. Points 1-5 are **loud** (return HTTP errors). Point 6 is **semi-loud** (returns structured ACCESS_DENIED). Point 7 is **silent** (restricts data, never errors).

| # | Enforcement Point | Layer | What Fires | Failure Mode |
|---|---|---|---|---|
| 1 | **IDP Authentication** | External IDP | PKCE / password / SSO | Login failed -- no JWT |
| 2 | **Claims Injection** | IDP Extension | Groups, role, email injected | Missing claims -- role resolution fails |
| 3 | **Federation Policy** | Databricks `/oidc/v1/token` | Issuer + audience + subject checked | `400/401/403` -- no DB token |
| 4 | **JWT Verification** | API Server | JWKS RS256 verify + audience + issuer | `401` -- request rejected |
| 5 | **Role to SP Mapping** | API Server | JWT role to SP application_id lookup | `403` -- unknown role |
| 6 | **Tool Access Control** | API Server (app-level) | Role in allowed_roles? | ACCESS_DENIED logged to audit |
| 7 | **UC Governance** | Databricks SQL Engine | Row filters, column masks, USE CONNECTION | Filtered/masked silently |

**Key insight**: A query that returns 0 rows is governance working, not a bug. NULL in a column means the column mask is active. These are silent, correct enforcement -- not errors.

### Error reference

| HTTP | Source | Error | Cause | Fix |
|---|---|---|---|---|
| `400` | App Server | Missing tool or role | Request body incomplete | Include both fields |
| `401` | /oidc/v1/token | invalid_grant | JWT signature invalid, issuer mismatch | Check JWKS keys, issuer URL |
| `401` | API Server | Invalid IDP token | JWKS verification failed | Check IDP JWKS endpoint, token expiry |
| `403` | /oidc/v1/token | Policy validation failed | No federation policy, or subject mismatch | Create/update policy on SP |
| `403` | API Server | Unknown role | Role not in ROLE_SP_MAP | Add role to config |
| `502` | App/API Server | Token exchange failed | Databricks rejected exchange | Check policy, SP status, JWT claims |
| `200` | Tool | ACCESS_DENIED | Role not in tool's allowed list | Expected -- logged to audit |
| `200` | SQL Engine | 0 rows returned | UC row filter excluded all rows | Expected -- governance working |
| `200` | SQL Engine | NULL in column | UC column mask active | Expected -- column masking |

---

## How to Add a New Role

1. **Create Databricks SP** in the account console
2. **Create workspace group** matching the role name, add SP to group
3. **Create federation policy** on the SP: same issuer, audiences, subject as other SPs
4. **Grant UC permissions**: USE_CATALOG, USE_SCHEMA, SELECT on tables, CAN_USE on warehouse
5. **Grant CAN_USE on MCP app** via permissions API
6. **Update ROLE_SP_MAP** in the token broker config with `"sp-role-name": "<sp-application-id>"`
7. **Update TOOL_ACCESS** if restricting tools: edit the tool access matrix in the MCP server
8. **Add IDP user** with role claim matching the claims injection rule
9. **Deploy** updated token broker

---

## Known Operational Gotchas

### Apps Proxy CAN_USE Requirement

Even with `authorization: disabled`, the Databricks Apps proxy requires the calling SP to have `CAN_USE` permission on the target app. New role SPs must be granted `CAN_USE` or token-exchanged requests get 401.

### Delta INSERT Needs SELECT

The audit table write (`INSERT INTO ...`) requires both `MODIFY` and `SELECT` grants on the table. Delta checks SELECT permission during the INSERT path.

### OAuth Integration Quota

Databricks accounts have a limit of 1000 OAuth custom integrations. Each Databricks App creation consumes one. If you hit the quota, delete unused apps first.

### ContextVar Thread Propagation

FastMCP runs synchronous tool functions in a thread pool. ContextVars set by async ASGI middleware do not propagate to these threads.

### Token Exchange Scope Constraint

Testing showed that narrowing the token exchange scope from `all-apis` to specific scopes (e.g., `sql genie serving`) can cause the Apps proxy to return 401, even with `authorization: disabled`. This is a platform constraint. UC governance still restricts at the data layer regardless of API scope.

---

## Implementation Checklist

### IDP Side

- [ ] Create API / Resource Server -- audience = Databricks workspace URL
- [ ] Create M2M / Service App -- for token broker (client_credentials flow)
- [ ] Create SPA App -- for browser login (PKCE flow), if needed
- [ ] Configure Users and Groups -- assign users to role-based groups
- [ ] Add Claims Injection -- inject groups, role, email into access token

### Databricks Side

- [ ] Create Role-Based Service Principals -- one SP per role
- [ ] Add SPs to Workspace Groups -- groups used by `is_member()` in row filters
- [ ] Create Federation Policies -- on each SP: issuer + audience + subject
- [ ] Configure UC Governance -- row filters, column masks, connection grants
- [ ] Deploy API Server + External App -- with IDP config + ROLE_SP_MAP

### Verification

- [ ] Get IDP JWT, decode, verify custom claims present
- [ ] Exchange JWT, get DB token, call `/api/2.0/preview/scim/v2/Me`, verify SP identity
- [ ] Call `SELECT is_member('group')` as each SP, verify group membership
- [ ] Call `SELECT * FROM data_table` as each SP, verify row filter applies
- [ ] Call denied tool as restricted SP, verify ACCESS_DENIED + audit record
