<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/token-federation.md, auth/_azure/token-federation.md, auth/_okta/token-federation.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation
  This file is auto-prepared and human-reviewed before publish.
-->

# Federation Exchange

> Bridging external identity providers to Databricks for users who don't have workspace accounts.

## The Problem

Your AI tools run on Databricks. Your partners, customers, or vendors authenticate with their own IdP. They don't have Databricks accounts. You need to give them governed access to Genie, Vector Search, Model Serving, and custom MCP tools without provisioning individual workspace users.

## The Pattern

Federation Exchange uses OAuth 2.0 Token Exchange (RFC 8693) to convert an external IdP token into a scoped Databricks service principal token.

```
External User authenticates with their IdP (Okta, Entra, Auth0)
       |
       v
Your app server verifies the IdP JWT (signature, claims, expiry)
       |
       v
App maps user's role claim to a Databricks service principal
       |
       v
Token Exchange: POST /oidc/v1/token (IdP JWT in, Databricks SP token out)
       |
       v
Databricks SP token used for SQL, Genie, Serving calls
       |
       v
UC governance fires per SP group membership (is_member())
```

## Two Federation Models

Databricks exposes two federation entry points, chosen by **who** is authenticating:

| Model | Who uses it | Setup | Flow |
|---|---|---|---|
| Account Token Federation | Users and service principals authenticating through your IdP | SSO enabled on the account; SCIM sync of users/SPs; up to 5 federated token issuers per account | Supports both U2M and M2M |
| Workload Identity Federation (WIF) | Automated workloads running outside Databricks (CI/CD runners, cloud VMs, Kubernetes pods) | Per-SP federation policy; no issuer limit | M2M only, using the workload runtime's own token (GitHub Actions OIDC, Azure Workload Identity, GCP service account) |

The role-based service principal pattern in this doc runs on Account Token Federation with M2M exchange: the external user's IdP token maps to a service principal via a role claim, rather than to an individual Databricks account.

### U2M vs M2M

| | U2M (user token) | M2M (service principal token) |
|---|---|---|
| Who authenticates | The external human user, via their IdP session | A backend service, using IdP client credentials |
| `client_id` in the exchange | Omitted — Databricks resolves via the account-wide policy | Required — selects which service principal receives the token |
| `current_user()` in UC | Resolves to the mapped Databricks identity | Resolves to the service principal |
| Typical use | Interactive apps where the user's own identity should govern row/column access | Backend jobs, scheduled tasks, or the role-based SP pattern in this doc |

## Role-Based Service Principals

Instead of one SP per external user (doesn't scale), map roles to SPs:

| External Role | Databricks SP | UC Group | Data Access |
|---------------|---------------|----------|-------------|
| Sales (West region) | `sp-role-west-sales` | `sales_west` | West region rows only |
| Sales (East region) | `sp-role-east-sales` | `sales_east` | East region rows only |
| Executive | `sp-role-executive` | `executives` | All regions, full columns |
| Finance | `sp-role-finance` | `finance` | All regions, financial columns |

One SP per role, not per user. N:1 mapping. UC governance applies via `is_member('group_name')` in row filters and column masks.

### Federation Policy

Each SP that participates in token exchange needs a federation policy configured in the Account Console. The policy defines which IdP tokens are trusted:

| Field | What it does |
|-------|-------------|
| Issuer | Must match the `iss` claim in the IdP JWT |
| Audience | Must match the `aud` claim (typically your workspace URL) |
| Subject | Must match the `sub` claim (the IdP's client ID or user identifier) |

The policy is the trust boundary. If the JWT doesn't match all three fields, the exchange returns 401.

### The Exchange Call

Regardless of IdP, the exchange itself is a single POST:

```bash
POST https://<workspace-hostname>/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<JWT from your IdP>
&subject_token_type=urn:ietf:params:oauth:token-type:jwt
&scope=all-apis
&client_id=<databricks-service-principal-uuid>   # required for role-based SP exchange
```

Response:

```json
{ "access_token": "<databricks-oauth-token>", "token_type": "Bearer", "expires_in": 3600 }
```

Use the `access_token` as a Bearer token for Databricks REST APIs, Model Serving, the Genie Conversation API, Vector Search, custom MCP servers on Databricks Apps, and the Databricks SDK (`WorkspaceClient(token=...)`).

### What Changes vs. What Stays When You Swap IdPs

| Changes | Stays the same |
|---------|---------------|
| Federation policy (issuer, audience, subject) | Service principals and their UC grants |
| IdP-specific claim names for role/email | UC row filters, column masks, connections |
| JWT verification keys (JWKS endpoint) | MCP tools, audit infrastructure |
| Login UI and user experience | The entire Databricks-side architecture |

This is the "IDP-agnostic" property: swap Auth0 for Okta, or Okta for Entra, by updating federation policies. No changes to UC governance, MCP tools, or audit.

### How It Differs from OBO

| | OBO | Federation |
|---|---|---|
| User has Databricks account | Yes | No |
| `current_user()` returns | Human email | SP application UUID |
| Row filters use | `current_user()` (individual) | `is_member()` (group-based) |
| Audit trail | Human identity in platform audit | SP in platform audit; human identity in app audit |
| Token source | Databricks Apps proxy injects it | Your app server exchanges for it |

### Governance Enforcement

Seven enforcement points in the chain, from IdP authentication through UC governance:

1. **IdP Authentication**: User logs in via their provider
2. **Claims Injection**: IdP adds role, email, groups to the JWT
3. **Federation Policy**: Databricks validates issuer + audience + subject
4. **JWT Verification**: App server verifies signature via JWKS
5. **Role Mapping**: JWT role claim resolved to SP application ID
6. **Tool Access Control**: App-level RBAC (which roles can use which tools)
7. **UC Governance**: Row filters, column masks, USE CONNECTION fire at SQL engine level

Points 1-5 are loud (HTTP errors on failure). Point 6 is semi-loud (structured ACCESS_DENIED). Point 7 is silent (fewer rows, masked columns).

## Token Lifetime (TTL) Behavior

Databricks copies the IdP token's `exp` claim verbatim into the exchanged token — it isn't extended or reset at exchange time.

- `exp` is an absolute timestamp, not a duration measured from the exchange call
- Exchange a **fresh** IdP token immediately before use rather than caching one and exchanging it later
- Long-running operations — polling Genie or Model Serving results, for example — need the exchanged token to stay valid for the full duration; a token that expires mid-poll returns `401` on the next call

| Flow | TTL controlled by |
|---|---|
| Federated M2M | IdP access policy sets `exp` |
| Federated U2M | IdP session/token lifetime policy |
| Native Databricks OAuth M2M (no federation) | Fixed 1 hour, set by Databricks |

## IdP-Specific Setup

The exchange call is identical for every IdP. What differs is how the subject token is obtained and how the federation policy is configured.

### Entra ID

Entra uses its built-in OIDC endpoints, so no custom authorization server is needed. The subject claim is typically `upn` (or `oid`), and the scope format follows `api://<app-id>/.default`.

### Okta

Okta uses a **custom Authorization Server** to define the audience, scopes, and access policy that Databricks validates against:

| Step | What to configure |
|---|---|
| Authorization Server | Okta Admin Console → Security → API → Authorization Servers; set an audience (for example `api://databricks`) that matches the Databricks federation policy audience |
| Scopes | Define custom scopes for U2M (for example `databricks-access`) and M2M (for example `databricks-token-federation`) |
| Access Policy | Grant those scopes to the Authorization Code (U2M) or Client Credentials (M2M) grant types |
| Application | Web Application with PKCE for U2M; API Services app for M2M |

Both PKCE (U2M) and DPoP are supported for additional token-binding security.

### Azure Managed Identity (workload federation)

An Azure workload (VM, AKS pod, Azure Function) fetches its token from Azure's Instance Metadata Service (IMDS) instead of an interactive login, then exchanges it the same way as any other IdP token:

```bash
AZURE_MI_TOKEN=$(curl -s \
  "http://169.254.169.254/metadata/instance/compute/identity/access_token?resource=<databricks-resource-id>" \
  -H "Metadata: true" | jq -r .access_token)
```

`<databricks-resource-id>` is Databricks' Azure application ID (`2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`). This path is a good fit for CI/CD runners, AKS pods, or Azure Functions that need to call Databricks without holding a Databricks secret — IMDS is only reachable from inside Azure compute, and the exchange applies to Azure Databricks workspaces.

## Gotchas

| Issue | Impact | Fix |
|---|---|---|
| Account limit: 5 federated token issuers | A 6th issuer registration fails with a non-obvious error | Consolidate issuers where possible; each environment (dev/stage/prod) counts toward the limit if it uses a distinct IdP issuer |
| JDBC/ODBC connections | Token exchange (RFC 8693) is API-only | Perform the exchange in application code and pass the resulting Databricks token to the driver, or route JDBC/ODBC callers through an API layer that performs the exchange server-side |
| `client_id` required for SP (role-based) exchange | Omitting `client_id` routes the exchange to the per-user account-wide policy instead of the intended service principal | Always include `client_id` (the Databricks SP UUID) for role-to-SP mapping in this pattern |
| Audience mismatch (`400 invalid_grant`) | The IdP token's `aud` claim doesn't match what the federation policy expects | Decode the token (for example at jwt.io) and confirm `aud` matches the policy audience exactly |
| Stale IdP token exchanged | Databricks copies `exp` verbatim, so an old IdP token produces an already-expired Databricks token | Always exchange a fresh IdP token immediately before use |
| Native Azure AD token used against Model Serving / Agent Bricks | These services expect a Databricks-issued OAuth token rather than a raw Entra token | Use the token-exchange flow above for Model Serving, Agent Bricks, and ML APIs; a direct Azure AD token works fine for workspace REST APIs (clusters, jobs, SQL) |

---

## Databricks Documentation

- [OAuth token federation](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation) (federation policies, WIF, token exchange mechanics)
- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) (token exchange mechanics)
- [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication) (SP patterns for AI apps)
- [Unity Catalog access control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) (grants, row filters)
