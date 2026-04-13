# UC HTTP Connections

> **Pillar 4**: Governing external service access

---

## The Business Challenge

Your AI agents need to call external services: SaaS APIs, partner systems, cloud provider endpoints, external MCP servers. Every external call introduces two governance questions:

1. **Who controls the credentials?** If API keys live in environment variables or app code, any developer with repo access has them. Rotation means redeploying every consumer.
2. **Who decides which agent can call which service?** Without centralized authorization, any agent that can reach the network can call any external API.

UC HTTP connections solve both by making credential storage and access authorization a Unity Catalog concern.

---

## How It Works

Application code never calls external services directly. It calls a Databricks-managed proxy endpoint, which checks authorization and injects credentials before forwarding to the external service.

```
Agent/App                  Databricks Proxy              External Service
    |                           |                              |
    |-- POST /proxy/conn_name ->|                              |
    |                           |-- USE CONNECTION check ------>|
    |                           |   (UC: does this identity     |
    |                           |    have the grant?)           |
    |                           |                              |
    |                           |-- Inject stored credential -->|
    |                           |   (app never sees raw key)    |
    |                           |                              |
    |                           |<-------- Response ------------|
    |<-------- Response --------|                              |
```

The app never holds the credential. Databricks injects it at proxy time. Revoke `USE CONNECTION` and access stops instantly, no redeploy, no code change.

---

## Four Authentication Methods

The key question: **what identity does the external service see?**

| Method | Databricks Identity | External Service Identity | Credential Lifecycle | Best For |
|---|---|---|---|---|
| **Bearer Token** | Per `current_user()` | Shared (one static token) | Manual rotation | Simple APIs with static keys |
| **OAuth M2M** | Per `current_user()` | Shared (service/app credentials) | Auto-refresh | Service-to-service, no user context needed |
| **OAuth U2M Shared** | Per `current_user()` | Shared (one user's OAuth token) | Auto-refresh | OAuth services without M2M support |
| **OAuth U2M Per User** | Per `current_user()` | **Per user (individual OAuth token)** | Auto-refresh per user | User-scoped data (personal Drive, Gmail, repos) |

All four methods enforce `USE CONNECTION` on the Databricks side. The difference is what identity the external service sees when the request arrives.

### Choosing the Right Method

```
Need per-user identity at the external service?
  |
  +-- Yes --> Does the external service support OAuth authorization code flow?
  |             +-- Yes --> U2M Per User
  |             +-- No  --> Not possible via UC connections; consider app-level auth
  |
  +-- No (shared access is fine)
        +-- External service supports OAuth client_credentials? --> M2M (recommended)
        +-- OAuth but no client_credentials grant?              --> U2M Shared
        +-- Static API key only?                                --> Bearer Token
```

### Choosing the Right Auth Method

| Method | Identity seen by external service | Credential lifecycle | Governance strength | Best for |
|---|---|---|---|---|
| **Bearer Token** | Shared service account | Manual rotation; stored in UC connection | Moderate — shared credential, audit shows connection use but not individual user | Internal APIs, services without OAuth |
| **OAuth M2M** | Shared service account | Auto-rotation via client credentials | Moderate — same as Bearer but credentials auto-refresh | SaaS APIs with OAuth support |
| **OAuth U2M Shared** | Shared service account (authorized by one user) | Single-user authorization; auto-refresh | Low — one user authorizes, all users use that identity | Quick setup; not recommended for audit |
| **OAuth U2M Per User** | Individual user | Each user authorizes separately; per-user refresh tokens | **High** — end-to-end per-user identity and audit trail | Regulated access, per-user audit requirements |

**The governance principle**: Use OAuth U2M Per User when you need per-user audit trails at the external service. Use Bearer Token or OAuth M2M when a shared service identity is acceptable and UC `USE CONNECTION` audit is sufficient.

---

## Bearer Token

Stores a static API key or PAT. All callers share the same credential.

- **Setup**: Provide `host` and `bearerToken` when creating the connection
- **Rotation**: Manual. Update the connection when the token expires.
- **External identity**: The entity the token was issued to (shared across all callers)

Simple but fragile. Token expiration requires manual intervention. Use OAuth methods when the external service supports them.

---

## OAuth M2M (Client Credentials)

Service-to-service authentication. Databricks exchanges client credentials for an access token automatically.

- **Setup**: Provide `clientId`, `clientSecret`, `tokenUrl`, and `scope`
- **Rotation**: Automatic. Databricks refreshes the token before expiration.
- **External identity**: The OAuth client application (shared across all callers)

Recommended over Bearer Token when the external service supports OAuth. No manual rotation, no token expiration emergencies.

---

## OAuth U2M Shared

One user authorizes the connection via browser-based OAuth consent. All callers use that user's refresh token.

- **Setup**: Provide `clientId`, `clientSecret`, `authUrl`, `tokenUrl`, `scope`. One user clicks "Sign in with HTTP" to authorize.
- **Rotation**: Automatic via refresh token.
- **External identity**: The authorizing user (shared across all callers)
- **Risk**: If the authorizing user leaves or revokes consent, the connection breaks for everyone.

Use when the external service supports OAuth but not the `client_credentials` grant (no M2M option).

---

## OAuth U2M Per User

Each user authenticates separately with the external service. True per-user identity propagation end-to-end.

- **Setup**: Same as U2M Shared, but each user completes their own OAuth consent flow on first use.
- **Rotation**: Per-user refresh tokens, managed automatically.
- **External identity**: The individual user (each caller has their own token)

This is the only method that provides **true end-to-end per-user access control** across both Databricks and the external service. Each user sees only their own data (their Drive files, their Gmail, their repos).

**Supported external services** (as of 2026-03): Google (Drive, Docs, Gmail, Calendar, Tasks), GitHub, Glean, SharePoint, and custom OAuth services that support the standard authorization code flow.

---

## Setup: OAuth Provider Configuration

Using Google as an illustrative example for U2M connections:

### 1. External OAuth Provider (Google Cloud Console)

- Create an **OAuth client ID** (Web application type)
- Add the Databricks redirect URI to **Authorized redirect URIs**:
  ```
  https://<workspace-url>/login/oauth/http.html
  ```
- Enable the APIs matching your requested scopes (Drive API, Docs API, Gmail API, etc.)
- Configure the **OAuth consent screen** (Internal for Google Workspace, External for personal accounts)

### 2. Databricks (Catalog Explorer > Connections > Create)

- Connection type: **HTTP**
- Host: `https://www.googleapis.com`
- Authorization endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
- Token endpoint: `https://oauth2.googleapis.com/token`
- OAuth scope: `offline_access https://www.googleapis.com/auth/drive ...`
- Enter Client ID and Client Secret
- Click **Sign in with HTTP** to complete OAuth consent

The `offline_access` scope is required to obtain a refresh token. Without it, Databricks cannot auto-refresh the access token after it expires.

---

## Provider Prerequisites (Service-Agnostic)

For any external service to work with UC HTTP connections U2M flow, it must meet six requirements. This applies regardless of whether the provider is Google, Salesforce, Microsoft, GitHub, or a custom OAuth service.

### Mandatory

| Requirement | Detail |
|---|---|
| **OAuth 2.0 Authorization Code Grant** | RFC 6749 Section 4.1. User redirected to authorization endpoint, grants consent, provider redirects back with an authorization code. |
| **Refresh token support** | Provider must issue a `refresh_token` in the token response. Without it, access dies after the access token expires. Some providers require a specific scope: Google (`offline_access`), Microsoft (`offline_access`), Salesforce (`refresh_token`). |
| **Configurable redirect URIs** | Provider must allow registering a custom redirect URI. Databricks sends `<workspace-url>/login/oauth/http.html`. |
| **Confidential client support** | Provider must support clients with a Client ID + Client Secret (not public/PKCE-only clients). |
| **Standard token endpoint** | Must accept `grant_type=authorization_code` for initial exchange and `grant_type=refresh_token` for renewal. |
| **HTTPS endpoints** | All authorization and token endpoints must be HTTPS. |

### Credential Exchange Flexibility

Databricks supports three methods for sending client credentials during token exchange:

| Method | How credentials are sent | Example provider |
|---|---|---|
| `header_and_body` (default) | Both Authorization header and request body | Google, most providers |
| `body_only` | Request body only | Some custom OAuth servers |
| `header_only` | Authorization header only | Okta |

### What breaks it

| Blocker | Detail |
|---|---|
| No authorization code grant | Provider only supports client_credentials (M2M) or device code flow |
| No refresh tokens | Provider issues access tokens only. Connection works once then dies after token expiry. |
| Proprietary auth extensions | Provider requires non-standard parameters in the token request |
| Admin policy blocking | Org admin must allowlist the OAuth Client ID (Google Workspace, Microsoft Entra, Okta) |
| Redirect URI restrictions | Provider restricts redirect URIs to pre-approved domains or patterns |

### Quick Checklist

Before attempting a U2M connection to any provider:

1. Does it have an **authorization endpoint** URL?
2. Does it have a **token endpoint** URL?
3. Can you create an OAuth client with a **Client ID + Client Secret**?
4. Can you register a **custom redirect URI**?
5. Does it issue **refresh tokens** (with what scope)?
6. Does it use **standard OAuth 2.0** token exchange parameters?

If all six are yes, it will work with UC HTTP connections U2M.

---

## Gotchas

| Issue | Detail | Resolution |
|---|---|---|
| `redirect_uri_mismatch` | Redirect URI in OAuth provider does not match what Databricks sends | Copy exact URI from the error details page into the OAuth provider config. No trailing slash, no spaces. |
| `admin_policy_enforced` | Organization admin blocks unauthorized third-party OAuth apps | Ask IT to allowlist the OAuth Client ID in the admin console (e.g., Google Admin > Security > API Controls) |
| **Connection name is immutable** | Once created, the name cannot be changed. It becomes part of the MCP proxy URL if marked as MCP connection. | Choose a stable, descriptive name at creation time. |
| **Owner has irrevocable USE CONNECTION** | The creator always has implicit access. | Transfer ownership via `ALTER CONNECTION ... SET OWNER TO ...` if the creator should lose access. |
| **`offline_access` scope missing** | Without a refresh token, the connection works for ~1 hour then fails silently. | Always include `offline_access` (Google) or equivalent scope for other providers. |
| **`isMcpConnection` cannot be toggled** | Once created, you cannot change the MCP flag. | Delete and recreate the connection if you need to change it. |

---

## USE CONNECTION Governance

`USE CONNECTION` is the SQL grant that controls access to HTTP connections.

```sql
-- Grant access to a group
GRANT USE CONNECTION ON CONNECTION google_api TO `data_team`;

-- Revoke access instantly
REVOKE USE CONNECTION ON CONNECTION google_api FROM `former_employee@example.com`;

-- View grants
SHOW GRANTS ON CONNECTION google_api;
```

`USE CONNECTION` does not inherit from catalog or schema grants. It is a standalone privilege. Every `USE CONNECTION` check is logged in `system.access.audit`.

Combined with Serverless Network Policies (SNP), this creates defense-in-depth: SNP defines which external destinations are reachable at the network layer, and `USE CONNECTION` controls which identities can authenticate to those destinations. Neither layer alone is sufficient; together they prevent both unauthorized access and credential leakage.

---

## Related

- [AI Gateway Patterns](ai-gateway-patterns.md): The four traffic patterns, including outbound external (Pattern 3) which uses UC Connections
- [Identity](../identity/): Identity model determines which SP/user is checked for USE CONNECTION
- [Data Governance](../data-governance/): Row filters and column masks govern data; connections govern tools
- [Observability](../observability/): Every USE CONNECTION attempt is audited in system tables

---

## References

- [Connect to external HTTP services](https://docs.databricks.com/en/query-federation/http.html)
- [External MCP via UC Connections](https://docs.databricks.com/en/generative-ai/mcp/connect-external-services.html)
- [Unity Catalog Privileges](https://docs.databricks.com/en/data-governance/unity-catalog/manage-privileges/privileges.html)
