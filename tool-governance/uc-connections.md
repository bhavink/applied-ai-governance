<!--
  Synced from databricks-fieldkit on 2026-09-14
  Sources: governance/http-connections.md, governance/service-credentials.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/query-federation/http
    - https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-services/service-credentials
  This file is auto-prepared and human-reviewed before publish.
-->

# UC HTTP Connections

> **Cloud**: Agnostic
> **Status**: Public Preview
> **Last verified**: 2026-07-01 (upstream: 2026-07-02)

---

## Region Availability

HTTP connections are only available in regions where **Model Serving** is supported. Check [Model serving features availability](https://learn.microsoft.com/en-us/azure/databricks/resources/feature-region-support#azure-model-serving) before deploying.

---

## TL;DR

UC HTTP connections store credentials for external HTTP services (REST APIs, MCP servers, SaaS platforms) in Unity Catalog. Access is governed by `USE CONNECTION`. Connections can be used for three purposes: (1) External MCP proxy endpoint, (2) `http_request()` SDK function for programmatic HTTP calls (deprecated — use proxy endpoint for new code), and (3) query federation via HTTP. Credentials are centrally managed — agent code and SQL never touch raw API keys.

**Required compute**: Databricks Runtime 15.4 LTS+ with Standard or Dedicated access mode, OR pro/serverless SQL warehouses on version 2023.40+.

---

## When to use

| Scenario | UC HTTP connection? |
|---|---|
| Agent needs to call an external MCP server | Yes — mark as MCP connection |
| SQL query needs to call a REST API (enrichment, lookup) | Yes — use `http_request()` |
| Credential rotation should be centralized, not per-app | Yes |
| Access to external service must be governed per-user/group | Yes — `USE CONNECTION` |
| Simple one-off API call from a notebook | Maybe — direct `requests` call is simpler if no governance needed |

---

## Creating HTTP connections

### Via UI

1. Catalog Explorer → **Connections** → **Create connection**
2. Connection type: **HTTP**
3. Configure:
   - **Name**: descriptive, stable (becomes part of proxy URL if MCP)
   - **Host**: base URL of the external service
   - **Base path** (optional): default path appended to host
   - **Authentication**: select method (see below)
   - **Is MCP connection**: check if this will be used as an MCP proxy endpoint
4. Click **Create**

### Via CLI

```bash
# Bearer token auth
databricks connections create \
  --connection-type HTTP \
  --name my_api_conn \
  --options '{
    "host": "https://api.example.com",
    "httpPath": "/v1",
    "bearerToken": "<api-key>"
  }'

# OAuth M2M (client credentials)
databricks connections create \
  --connection-type HTTP \
  --name my_oauth_conn \
  --options '{
    "host": "https://api.example.com",
    "httpPath": "/v1",
    "clientId": "<client-id>",
    "clientSecret": "<client-secret>",
    "tokenUrl": "https://auth.example.com/oauth/token",
    "scope": "read write"
  }'

# MCP connection (add isMcpConnection flag)
databricks connections create \
  --connection-type HTTP \
  --name github_mcp \
  --options '{
    "host": "https://api.github.com",
    "httpPath": "/mcp",
    "bearerToken": "<github-pat>",
    "isMcpConnection": true
  }'
```

### Via Python SDK

```python
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()

# Create with bearer token
conn = w.connections.create(
    name="my_api_conn",
    connection_type="HTTP",
    options={
        "host": "https://api.example.com",
        "httpPath": "/v1",
        "bearerToken": "<api-key>",
    },
)
```

---

## Authentication methods

Five methods now available (updated Sep 2026), each with different identity propagation characteristics. The key question: **what identity does the external service see?**

| Method | Databricks identity (USE CONNECTION) | External service identity | Credential lifecycle |
|---|---|---|---|
| Bearer Token | Per current_user() | Shared (one static token) | Manual rotation |
| OAuth M2M | Per current_user() | Shared (service/app credentials) | Auto-refresh |
| OAuth U2M Shared | Per current_user() | Shared (one user's OAuth token) | Auto-refresh |
| OAuth U2M Per User | Per current_user() | Per user (individual OAuth token) | Auto-refresh per user |
| **Dynamic Client Registration (DCR)** (NEW) | **Per current_user()** | **Per user (individual OAuth token)** | **Auto-refresh per user** |

### Method 5: Dynamic Client Registration (DCR) — GA (Sep 2026)

DCR uses [RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591) to automatically discover OAuth endpoints and register a client. You provide only the host URL — Databricks discovers the authorization server, registers OAuth credentials, and manages per-user consent flows automatically. Each user completes an OAuth consent flow on first use, then Databricks stores per-user refresh tokens.

```json
{
  "host": "https://api.example.com",
  "base_path": "/mcp",
  "oauth_scope": "read write"
}
```

| Pros | Cons |
|---|---|
| Zero OAuth app registration required | External service must support OAuth 2.0 DCR (RFC 7591) |
| Per-user identity at external service | Cannot use `http_request()` in SQL (Python SDK only) |
| Ideal for MCP servers that support DCR | |
| Automatic OAuth discovery and registration | |

> **DCR is the recommended auth method for MCP servers that support it.** Databricks manages OAuth credentials on your behalf — no manual client registration needed.

### Decision framework

```
Need per-user identity at the external service?
  ├── Yes → OAuth U2M Per User (if supported)
  │         First-time: user gets OAuth consent prompt
  │         After: Databricks stores per-user refresh token
  │
  └── No (shared access is fine)
        ├── External service supports OAuth? → OAuth M2M (recommended) or U2M Shared
        └── Static API key only? → Bearer Token
```

### Method 1: Bearer Token

Simplest. Stores a static API key or PAT. All callers share the same token.

```json
{
  "host": "https://api.example.com",
  "bearerToken": "<api-key>"
}
```

| Pros | Cons |
|---|---|
| Simple setup | Token expires, manual rotation required |
| Works with any API that accepts Bearer auth | No per-user identity at external service |
| | Databricks App targets: token expires ~1hr |

**Governance**: `USE CONNECTION` controls who can call. External service sees one identity for all callers.

### Method 2: OAuth M2M (Client Credentials)

Service-to-service auth. Databricks exchanges client credentials for an access token automatically.

```json
{
  "host": "https://api.example.com",
  "clientId": "<client-id>",
  "clientSecret": "<client-secret>",
  "tokenUrl": "https://auth.example.com/oauth/token",
  "scope": "read write"
}
```

| Pros | Cons |
|---|---|
| Auto-refresh, no manual token rotation | Requires OAuth-capable external service |
| Standard OAuth 2.0 | Shared identity (org-level bot) |

**Governance**: `USE CONNECTION` controls who can call. External service sees the app/service principal identity. Recommended over U2M Shared when the external service supports client_credentials grant.

### OAuth 2.0 RFC Compliance Requirement

HTTP connections using OAuth must connect to services that comply with the official [OAuth 2.0 specification (RFC 6750)](https://datatracker.ietf.org/doc/html/rfc6750#section-4). This means the service's responses must use exact field names and data formats as specified: `access_token`, `expires_in`, etc.

If you have problems connecting using OAuth 2.0, verify the external service's responses follow the RFC specification. Databricks cannot accept services with non-compliant OAuth implementations.

### Method 3: OAuth U2M Shared

One user authorizes the connection. All callers use that user's refresh token.

```json
{
  "host": "https://api.example.com",
  "authType": "OAuthU2MShared",
  "clientId": "<client-id>",
  "clientSecret": "<client-secret>",
  "authUrl": "https://auth.example.com/authorize",
  "tokenUrl": "https://auth.example.com/token",
  "scope": "read"
}
```

| Pros | Cons |
|---|---|
| Auto-refresh via stored refresh token | Single user's identity for all callers |
| Works with OAuth services that don't support M2M | Refresh token tied to one user's authorization |

**Governance**: `USE CONNECTION` controls who can call. External service sees the authorizing user's identity for all callers. If that user leaves or revokes consent, the connection breaks for everyone.

**Redirect URL**: The external OAuth provider may need `<databricks_workspace_url>/login/oauth/http.html` allowlisted.

### Method 4: OAuth U2M Per User

Each user authenticates separately with the external service. True per-user identity propagation end-to-end.

```json
{
  "host": "https://api.example.com",
  "authType": "OAuthU2MPerUser",
  "clientId": "<client-id>",
  "clientSecret": "<client-secret>",
  "authUrl": "https://auth.example.com/authorize",
  "tokenUrl": "https://auth.example.com/token",
  "scope": "channels:read channels:history chat:write"
}
```

| Pros | Cons |
|---|---|
| True per-user identity at external service | Each user must complete OAuth consent flow once |
| Per-user data scoping (personal repos, per-user SaaS) | Higher setup complexity |
| Individual audit trail at external service | Not all providers supported |
| User leaves = only their access breaks, not everyone's | |

**Governance**: Both layers are per-user:
1. `USE CONNECTION` checks `current_user()` on the Databricks side
2. External service checks the individual user's OAuth token

This is the only method that provides **true end-to-end per-user access control** across Databricks and the external service.

**Redirect URL**: The external OAuth provider must allowlist `<databricks_workspace_url>/login/oauth/http.html`.

#### Walkthrough: Google OAuth U2M

Setting up a U2M Per User connection to Google APIs (Drive, Docs, Gmail, Calendar, Tasks):

1. **Google Cloud Console**: APIs & Services > Credentials > Create Credentials > OAuth client ID
   - Application type: **Web application**
   - Authorized redirect URI: `https://<your-workspace-url>/login/oauth/http.html` (exact match required)
   - Note the **Client ID** and **Client Secret**

2. **Enable Google APIs**: APIs & Services > Enabled APIs. Enable the APIs matching your requested scopes (Drive API, Docs API, Gmail API, Calendar API, etc.)

3. **OAuth consent screen**: Configure as Internal (Google Workspace) or External. Add the scopes you need.

4. **Databricks UI**: Catalog Explorer > Connections > Create connection > HTTP
   - Host: `https://www.googleapis.com`
   - Authorization endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
   - Token endpoint: `https://oauth2.googleapis.com/token`
   - OAuth scope: `offline_access https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents ...`
   - Enter Client ID and Client Secret, click **Sign in with HTTP**

5. **Common errors**:

| Error | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | Redirect URI in Google Console does not match what Databricks sends | Copy exact URI from error details into Google Console (no trailing slash, no spaces) |
| `admin_policy_enforced` | Google Workspace admin blocks unauthorized third-party OAuth apps | Ask IT to allowlist the OAuth Client ID in Google Admin > Security > API Controls > App Access Control |
| `invalid_scope` | Requested scope not enabled on the Google Cloud project | Enable the corresponding API in Google Cloud Console |

> **`offline_access` scope**: Required to obtain a refresh token. Without it, Databricks cannot auto-refresh the access token after it expires (~1 hour).

**Credential exchange method**: Providers differ in how they accept client credentials during token exchange:
- `header_and_body` (default): credentials in both authorization header and request body
- `body_only`: credentials only in request body
- `header_only`: credentials only in authorization header (e.g., Okta)

> **Supported providers for U2M Per User** (as of 2026-03): GitHub, Glean, Google Drive, SharePoint, and custom OAuth services that support standard authorization code flow.

### Managed OAuth Providers (Databricks manages credentials)

For select providers, Databricks manages the OAuth credentials in the backend — you do NOT register your own OAuth app. When creating a connection, select **OAuth User to Machine Per User** and choose the provider name.

For the complete list of supported providers, their configuration notes, and scopes, see [Services with managed OAuth support](https://learn.microsoft.com/en-us/azure/databricks/agents/mcp-tools/managed-oauth#services-with-managed-oauth-support).

**Common managed providers include:**
- **Glean MCP** — Enterprise search, chat, documents, agent tools
- **GitHub MCP** — Repositories, organizations, project data  
- **Atlassian MCP** — Jira issues, Confluence content
- **Slack MCP** — Slack messages, files, channels, canvases, DMs, history

If using Managed OAuth, allowlist these redirect URIs if your IdP requires it:

| Cloud | Redirect URI |
|---|---|
| AWS | `https://oregon.cloud.databricks.com/api/2.0/http/oauth/redirect` |
| Azure | `https://westus.azuredatabricks.net/api/2.0/http/oauth/redirect` |
| GCP | `https://us-central1.gcp.databricks.com/api/2.0/http/oauth/redirect` |

> **Why this matters**: Managed OAuth eliminates manual OAuth app registration. For GitHub, Glean, Atlassian, and Slack MCP connections, just select the provider — Databricks handles client registration and token management. Per-user identity is automatic.

---

## USE CONNECTION privilege

`USE CONNECTION` is the UC privilege that controls access to HTTP connections.

```sql
-- Grant to a group
GRANT USE CONNECTION ON CONNECTION my_api_conn TO `data_team`;

-- Grant to a service principal (for automated agents)
GRANT USE CONNECTION ON CONNECTION my_api_conn TO ``;

-- Revoke
REVOKE USE CONNECTION ON CONNECTION my_api_conn FROM `former_employee@example.com`;

-- View grants
SHOW GRANTS ON CONNECTION my_api_conn;
```

### Key behaviors

| Behavior | Detail |
|---|---|
| **Connection owner** | Has implicit `USE CONNECTION` — cannot be revoked |
| **Transfer ownership** | `ALTER CONNECTION my_api_conn SET OWNER TO \`new_owner@example.com\`` |
| **Inheritance** | `USE CONNECTION` does NOT inherit from catalog/schema grants — it's a standalone privilege |
| **Audit** | All `USE CONNECTION` checks logged in `system.access.audit` |

---

## UC Connections Proxy Endpoint — RECOMMENDED (replaces http_request())

> **`http_request()` is deprecated.** Use the UC connections proxy endpoint for new code.

The proxy endpoint forwards requests to external services while injecting stored credentials. Your code authenticates with Databricks; Databricks handles external auth.

**Proxy endpoint URL format:**
```
https://<workspace-hostname>/api/2.0/unity-catalog/connections/<connection-name>/proxy[/<sub-path>]
```

URL construction: `{connection host}{base_path}{sub-path}`

**Example:**
```bash
# Slack message via proxy (Slack bearer token stored in connection, never in client)
curl -X POST \
  "https://<workspace>/api/2.0/unity-catalog/connections/slack_connection/proxy/chat.postMessage" \
  -H "Authorization: Bearer <databricks-token>" \
  -H "Content-Type: application/json" \
  -d '{"channel": "C123456", "text": "Hello!"}'
```

**Supported HTTP methods:** `GET`, `POST`, `PUT`, `PATCH`, `DELETE`

**Header forwarding rules:**
- `Authorization`, `Cookie`, `X-Databricks-*` headers are **stripped** before forwarding (prevents credential leakage)
- All other headers passed through unchanged

### SDK proxy pattern (Python)

```python
from databricks_openai import DatabricksOpenAI
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()

# Route OpenAI calls through the UC proxy — never hold the OpenAI key in code
client = DatabricksOpenAI(
    workspace_client=w,
    base_url=f"{w.config.host}/api/2.0/unity-catalog/connections/openai_connection/proxy/",
)

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello!"}],
)
```

### Slack via SDK proxy

```python
from slack_sdk import WebClient
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()
client = WebClient(
    token=w.config.authenticate()["Authorization"].split(" ")[1],
    base_url=f"{w.config.host}/api/2.0/unity-catalog/connections/slack_connection/proxy/",
)
result = client.chat_postMessage(channel="C123456", text="Hello!")
```

---

## http_request() SQL function (DEPRECATED as of Sep 2026)

> **DEPRECATED** — use the proxy endpoint for new code.

```sql
-- Still works but prefer proxy endpoint
SELECT http_request(
    conn => 'my_api_conn',
    method => 'GET',
    path => '/customers/12345'
) AS response;
```

**Blocked for**: U2M Per User and Dynamic Client Registration (DCR) connection types. Use Python SDK / proxy endpoint for these auth types — SQL `http_request()` is not compatible.

### Python SDK alternative (use when SQL http_request() is blocked)

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.serving import ExternalFunctionRequestHttpMethod

w = WorkspaceClient()
result = w.serving_endpoints.http_request(
    conn="my_api_conn",
    method=ExternalFunctionRequestHttpMethod.POST,
    path="/api/v1/resource",
    json={"key": "value"},
    headers={"extra-header-key": "extra-header-value"},
)
```

> **Rate limiting**: `http_request` (both SQL and SDK) is rate limited — designed for interactive/agent use, not high-volume batch queries. For many rows, batch IDs and call a bulk API endpoint, or use the proxy endpoint with the provider's SDK.

### Use cases (legacy)

- **Data enrichment**: Look up external data mid-query (geocoding, company info, exchange rates)
- **Webhook triggers**: Fire notifications from SQL pipelines
- **API aggregation**: Combine multiple API responses in a single query

---

## Query federation via HTTP

HTTP connections enable query federation — querying external REST APIs as if they were tables.

### Pattern: API enrichment in SQL

```sql
-- Enrich internal data with external API lookup
WITH customer_data AS (
    SELECT customer_id, name, country_code
    FROM prod.crm.customers
    WHERE tier = 'enterprise'
),
enriched AS (
    SELECT
        c.*,
        http_request(
            connection_name => 'company_api',
            method => 'GET',
            path => CONCAT('/companies/', c.customer_id)
        ):body:employee_count AS employee_count
    FROM customer_data c
)
SELECT * FROM enriched;
```

> **Performance warning**: `http_request()` makes one HTTP call per row. For large datasets, batch the IDs and call a bulk API endpoint, or pre-materialize the external data into a UC table.

---

## Managing connections

### List connections

```bash
databricks connections list
```

```python
for conn in w.connections.list():
    if conn.connection_type == "HTTP":
        print(f"{conn.name}: {conn.options.get('host', 'N/A')}")
```

### Update credentials

```bash
databricks connections update my_api_conn \
  --options '{"host": "https://api.example.com", "bearerToken": "<new-token>"}'
```

### Delete

```bash
databricks connections delete my_api_conn
```

> **Deletion impact**: Deleting a connection immediately breaks all agents and queries that reference it. External MCP proxy URL stops working. No grace period.

---

## Network Security for HTTP Connections

Routes HTTP connection traffic through your workspace's serverless compute plane. Secure this traffic using Private Link (recommended) or IP allowlisting.

### Private Link (recommended)

For external services inside your VNet/VPC, configure Private Link for complete tenant isolation. Only your Databricks workspace can reach your service. Traffic travels over a private connection rather than the public internet.

To configure: [Configure private connectivity to resources in your VNet](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/pl-to-internal-network). For proxy setup patterns, see [Private and Dedicated Connectivity Patterns for Databricks Serverless](https://community.databricks.com/t5/technical-blog/private-and-dedicated-connectivity-patterns-for-databricks/ba-p/91134).

### IP Allowlisting

If Private Link is not available, configure your external service's firewall to allowlist Databricks serverless outbound IPs. Note: outbound IPs are shared across Databricks customers, so this approach does NOT provide tenant isolation.

For serverless outbound IPs and instructions: [Configure network security perimeter (NSP) for Azure resources](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/serverless-firewall-config).

**BREAKING CHANGE**: Workspaces created before March 2026 may reference **control plane IPs** instead of **serverless IPs** in firewall rules. Update allowlists before **May 30, 2026** to avoid connectivity failures. See [Migrate to serverless routing for HTTP connections](https://learn.microsoft.com/en-us/azure/databricks/query-federation/http-migration).

---

## CREATE CONNECTION SQL syntax

```sql
-- Bearer token
CREATE CONNECTION my_api_conn TYPE HTTP
OPTIONS (
  host 'https://api.example.com',
  port '443',
  base_path '/v1',
  bearer_token secret ('<secret-scope>', '<secret-key>')  -- use secrets, not plaintext
);

-- OAuth M2M
CREATE CONNECTION my_oauth_conn TYPE HTTP
OPTIONS (
  host 'https://api.example.com',
  port '443',
  base_path '/v1',
  client_id '<client-id>',
  client_secret '<client-secret>',
  oauth_scope 'read write',
  token_endpoint 'https://auth.example.com/oauth/token'
);
```

> Note: OAuth U2M Shared **cannot** be created via SQL — must use the Catalog Explorer UI.

---

## Gotchas

| Issue | Detail |
|---|---|
| **Bearer token expiration** | Tokens stored in connections expire. For Databricks App targets, ~1hr. For SaaS APIs, varies. Use OAuth methods for auto-refresh. |
| **Connection name is immutable** | Once created, the name cannot be changed. It becomes part of the MCP proxy URL. Choose carefully. |
| **Owner has irrevocable USE CONNECTION** | The creator always has implicit access. Transfer ownership via `ALTER CONNECTION ... SET OWNER TO ...` if the creator should lose access. |
| **`isMcpConnection` cannot be changed** | Once a connection is created, you cannot toggle the MCP flag. Delete and recreate if you need to change it. |
| **http_request() is per-row (DEPRECATED)** | In SQL, each row triggers a separate HTTP call. Use proxy endpoint with batch APIs instead. |
| **`unity-catalog` scope required** | The calling token must include `unity-catalog` scope to access the MCP proxy. Without it: `403: "does not have required scopes: unity-catalog"`. |
| **http_request() blocked for DCR and U2M Per User** | Use Python SDK / proxy endpoint for these auth types — SQL http_request() does not work with them. |
| **OAuth services must be RFC 6750 compliant** | Databricks cannot connect to OAuth services with non-compliant implementations. Verify the external service returns responses with exact RFC field names (`access_token`, `expires_in`, etc.). |
| **BREAKING: firewall IP migration by May 30, 2026** | Workspaces pre-March 2026 must migrate from control plane IPs to serverless IPs in firewall allowlists. |
| **Data transfer charges** | HTTP connections may incur Databricks data transfer charges. See [Data transfer and connectivity pricing](https://www.databricks.com/product/pricing/data-transfer-connectivity). |
| **Rate limiting on http_request()** | `http_request` is designed for interactive/agent use, not high-volume batch queries. For many rows, batch IDs and call a bulk API endpoint, or use proxy endpoint with provider SDK. |

---

## Related

- [`best-practices.md`](best-practices.md) — USE CONNECTION governance patterns, confused deputy prevention
- [`unity-catalog.md`](unity-catalog.md) — Core UC privilege reference
- [`../mcp/external-mcp.md`](../mcp/external-mcp.md) — External MCP via UC HTTP connections
- [`../mcp/external-connection-tools.md`](../mcp/external-connection-tools.md) — Agent Framework external connection tools
- [`../auth/oauth-scopes.md`](../auth/oauth-scopes.md) — `unity-catalog` scope requirement

# Service Credentials — Governed Access to External Cloud Services

> **TL;DR**: A service credential is a Unity Catalog securable that wraps a cloud identity (AWS IAM role, Azure managed identity, GCP service account) to give Databricks users governed access to external cloud services. Unlike storage credentials (for S3/ADLS/GCS locations), service credentials target services like Secrets Manager, Key Vault, Pub/Sub, Glue, Bedrock, etc. Access is controlled per user/group/SP via `GRANT ACCESS`, not per compute resource.

---

## When to Use What

| Need | Use |
|---|---|
| UC managed/external storage locations | **Storage credential** |
| Access external cloud services (APIs, secrets, queues) | **Service credential** |
| Lakehouse Federation connection to external DB | **Service credential** with `CREATE CONNECTION` grant |
| AI Gateway external model (e.g. Bedrock) | **Service credential** (referenced in endpoint config) |

---

## Cloud Comparison

| Aspect | AWS | Azure | GCP |
|---|---|---|---|
| **Cloud identity** | IAM role (customer-created) | Managed identity via Access Connector | GCP service account (Databricks-generated) |
| **Setup flow** | Create IAM role, register in Databricks, update trust policy with external ID | Create Access Connector + MI, grant MI roles on target service, register in Databricks | Create credential in Databricks, grant the generated SA roles in GCP console |
| **Self-referencing requirement** | Yes (self-assuming IAM role, enforced since Sep 2024) | N/A | N/A |
| **Trust mechanism** | Cross-account STS:AssumeRole to UC Master Role + external ID | Azure Databricks Access Connector resource ID | Databricks-managed SA, no  management |
| **Credential returned by `dbutils`** | `botocore.session.Session` (for boto3) / `AWSCredentialsProvider` (Java) | `TokenCredential` (Azure SDK) | `google.auth.credentials.Credentials` / `GoogleCredentials` (Java) |
| **Terraform block** | `aws_iam_role { role_arn = "..." }` | `azure_managed_identity { access_connector_id = "..." }` | `databricks_gcp_service_account {}` (empty, SA email is output) |

---

## Prerequisites

**All clouds:**
- Unity Catalog-enabled workspace
- `CREATE SERVICE CREDENTIAL` privilege on the metastore (account admins, metastore admins, and auto-enabled workspace admins have this by default)
- Compute on **Databricks Runtime 16.2+** for code usage (with multi-language support: Python, Scala, R, SQL)
- **DBR 16.1 and below**: Python code only — Scala and R language support requires DBR 16.2+
- DBR 15.4 LTS+: Python-only support (Public Preview)

> **Azure-specific**: Service principals must have the **account admin** role to create a service credential that uses a managed identity. You cannot delegate `CREATE SERVICE CREDENTIAL` to a service principal.

---

## Create — Per Cloud

### AWS

#### 1. Create IAM Role

The role **must be self-assuming** (trust itself in the trust policy). Non-self-assuming roles have been blocked since September 2024.

**Initial trust policy** (placeholder external ID `0000`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"
        ]
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "0000"
        }
      }
    }
  ]
}
```

> **GovCloud**: Use `arn:aws-us-gov:iam::044793339203:role/unity-catalog-prod-UCMasterRole-1QRFA8SGY15OJ`
> **GovCloud DoD**: Use `arn:aws-us-gov:iam::170661010020:role/unity-catalog-prod-UCMasterRole-1DI6DL6ZP26AS`

#### 2. Attach permissions policy for the target service

**Secrets Manager example:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["secretsmanager:GetResourcePolicy", "secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:us-west-2:111122223333:secret:my-secret-*"],
      "Effect": "Allow"
    },
    {
      "Action": ["sts:AssumeRole"],
      "Resource": ["arn:aws:iam::<ACCOUNT-ID>:role/<THIS-ROLE-NAME>"],
      "Effect": "Allow"
    }
  ]
}
```

**Glue example:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase", "glue:GetDatabases",
        "glue:GetTable", "glue:GetTables",
        "glue:GetPartition", "glue:GetPartitions",
        "glue:GetUserDefinedFunction", "glue:GetUserDefinedFunctions",
        "glue:BatchGetPartition"
      ],
      "Resource": [
        "arn:aws:glue:<REGION>:<ACCOUNT-ID>:table/*/*",
        "arn:aws:glue:<REGION>:<ACCOUNT-ID>:catalog*",
        "arn:aws:glue:<REGION>:<ACCOUNT-ID>:database/<DB-NAME>"
      ]
    },
    {
      "Action": ["sts:AssumeRole"],
      "Resource": ["arn:aws:iam::<ACCOUNT-ID>:role/<THIS-ROLE-NAME>"],
      "Effect": "Allow"
    }
  ]
}
```

#### 3. Register in Databricks

Catalog > External Data > Credentials > Create credential > Service Credential. Enter name + IAM role ARN. Copy the generated **external ID**.

#### 4. Update IAM trust policy

Replace `0000` with the real external ID, add self-assumption:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL",
          "arn:aws:iam::<YOUR-ACCOUNT-ID>:role/<THIS-ROLE-NAME>"
        ]
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<SERVICE-CREDENTIAL-EXTERNAL-ID>"
        }
      }
    }
  ]
}
```

#### 5. Validate

In Databricks: Catalog > External Data > Credentials > select credential > validate. Confirm "Self Assume Role" check passes (takes 1-2 minutes).

---

### Azure

#### 1. Create Azure Databricks Access Connector

In Azure portal, create an Access Connector and assign the managed identity the required RBAC roles on the target service. You need **Contributor** role or higher on the access connector resource.

> **Managed identity is strongly recommended** over service principal. MIs can access service accounts protected by network rules and eliminate secret rotation.

#### 2. Register in Databricks

Catalog > External Data > Credentials > Create credential > Service Credential.

Enter:
- Credential name
- Access connector resource ID:
  ```
  /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Databricks/accessConnectors/<name>
  ```
- (Optional) User-assigned managed identity ID:
  ```
  /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>
  ```

---

### GCP

#### 1. Create credential in Databricks

Catalog > External Data > Credentials > Create credential > Service Credential. Enter a name.

Databricks **generates a GCP service account** automatically. Note the service account email (format: `<id>@<project>.iam.gserviceaccount.com`).

#### 2. Grant the SA access in GCP console

Open the target GCP service, add the Databricks-generated SA email as a principal with the required IAM roles.

---

## SQL Commands

All SQL commands require **Databricks Runtime 16.2+** (15.4 LTS+ for some). No version requirement for Catalog Explorer or REST API.

```sql
-- List all service credentials
SHOW SERVICE CREDENTIALS;

-- View properties
DESCRIBE SERVICE CREDENTIAL <credential-name>;

-- Grant access to use the credential
GRANT ACCESS ON SERVICE CREDENTIAL <credential-name> TO <principal>;

-- Grant ability to create Lakehouse Federation connections
GRANT CREATE CONNECTION ON SERVICE CREDENTIAL <credential-name> TO <principal>;

-- Show grants
SHOW GRANTS [<principal>] ON SERVICE CREDENTIAL <credential-name>;

-- Revoke
REVOKE ACCESS ON SERVICE CREDENTIAL <credential-name> FROM <principal>;
REVOKE CREATE CONNECTION ON SERVICE CREDENTIAL <credential-name> FROM <principal>;

-- Change owner
ALTER SERVICE CREDENTIAL <credential-name> OWNER TO <principal>;

-- Rename
ALTER SERVICE CREDENTIAL <credential-name> RENAME TO <new-name>;

-- Delete
DROP SERVICE CREDENTIAL [IF EXISTS] <credential-name>;
```

> Principals with spaces, dashes, or `@` need backtick quoting: `` `finance team` ``

### Privileges

| Privilege | Grants |
|---|---|
| `ACCESS` | Use the credential to access external cloud services |
| `CREATE CONNECTION` | Create Lakehouse Federation connections using this credential |

---

## Use in Code

### Python — AWS (boto3)

```python
import boto3

boto3_session = boto3.Session(
    botocore_session=dbutils.credentials.getServiceCredentialsProvider('my-aws-cred'),
    region_name='us-west-2'
)
sm = boto3_session.client('secretsmanager')
secret = sm.get_secret_value(SecretId='my-secret')
```

### Python — Azure (Azure SDK)

```python
from azure.keyvault.secrets import SecretClient

credential = dbutils.credentials.getServiceCredentialsProvider('my-azure-cred')
client = SecretClient(
    vault_url="https://my-vault.vault.azure.net/",
    credential=credential
)
secret = client.get_secret("my-secret")
```

### Python — GCP (google-cloud SDK)

```python
from google.cloud import pubsub_v1

credentials = dbutils.credentials.getServiceCredentialsProvider('my-gcp-cred')
publisher = pubsub_v1.PublisherClient(credentials=credentials)
topic_path = publisher.topic_path('my-project', 'my-topic')
future = publisher.publish(topic_path, b"Hello from Databricks")
print(f"Published: {future.result(timeout=5)}")
```

### Scala — AWS (Java SDK)

```scala
import com.amazonaws.auth.AWSCredentialsProvider
import com.amazonaws.services.s3.AmazonS3ClientBuilder

val awsCreds = dbutils.credentials
  .getServiceCredentialsProvider("my-aws-cred")
  .asInstanceOf[AWSCredentialsProvider]

val s3 = AmazonS3ClientBuilder.standard()
  .withCredentials(awsCreds)
  .withRegion("us-east-1")
  .build()
```

### Scala — Azure (Java SDK)

```scala
import com.azure.security.keyvault.secrets.{SecretClient, SecretClientBuilder}

val credential = dbutils.credentials.getServiceCredentialsProvider("my-azure-cred")
val client = new SecretClientBuilder()
  .vaultUrl("https://my-vault.vault.azure.net/")
  .credential(credential)
  .buildClient()
```

### Scala — GCP (Java SDK)

```scala
import com.google.auth.oauth2.GoogleCredentials
import com.google.cloud.pubsub.v1.Publisher
import com.google.pubsub.v1.TopicName
import com.google.api.gax.core.FixedCredentialsProvider

val gcpCreds = dbutils.credentials
  .getServiceCredentialsProvider("my-gcp-cred")
  .asInstanceOf[GoogleCredentials]

val publisher = Publisher.newBuilder(TopicName.of("my-project", "my-topic"))
  .setCredentialsProvider(FixedCredentialsProvider.create(gcpCreds))
  .build()
```

### In UDFs

Use `databricks.service_credentials.getServiceCredentialsProvider()` (not `dbutils.credentials`):

```python
# Inside a UDF
from databricks.service_credentials import getServiceCredentialsProvider
cred = getServiceCredentialsProvider('my-cred')
```

### Default Service Credential (cluster-level)

Set environment variable on the cluster (Advanced > Spark tab > Environment variables):

```
DATABRICKS_DEFAULT_SERVICE_CREDENTIAL_NAME=my-cred
```

When set, SDK clients use the credential automatically without explicit naming:

```python
# AWS — no credential argument needed
sm = boto3.client('secretsmanager', region_name='us-west-2')

# Azure — uses DefaultAzureCredential
from azure.identity import DefaultAzureCredential
credential = DefaultAzureCredential()

# GCP — no credential argument needed
publisher = pubsub_v1.PublisherClient()
```

> **** on serverless compute or SQL warehouses.

---

## Terraform

The unified resource is **`databricks_credential`** with `purpose = "SERVICE"`. There is no separate `databricks_service_credential` resource.

### AWS

```hcl
# --- IAM Role ---
resource "aws_iam_role" "svc_cred" {
  name               = "databricks-svc-cred"
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json
}

data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  aws_account_id = var.aws_account_id
  role_name      = aws_iam_role.svc_cred.name
  external_id    = databricks_credential.svc_cred.aws_iam_role[0].external_id
}

resource "aws_iam_role_policy" "secrets_access" {
  role   = aws_iam_role.svc_cred.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:GetResourcePolicy"]
        Resource = ["arn:aws:secretsmanager:us-west-2:${var.aws_account_id}:secret:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [aws_iam_role.svc_cred.arn]
      }
    ]
  })
}

# --- Service Credential ---
resource "databricks_credential" "svc_cred" {
  name = "aws-secrets-cred"
  aws_iam_role {
    role_arn = aws_iam_role.svc_cred.arn
  }
  purpose = "SERVICE"
  comment = "Access to AWS Secrets Manager"
}

resource "databricks_grants" "svc_cred" {
  credential = databricks_credential.svc_cred.id
  grant {
    principal  = "Data Engineers"
    privileges = ["ACCESS"]
  }
}
```

### Azure

```hcl
# --- Access Connector ---
resource "azurerm_databricks_access_connector" "svc" {
  name                = "databricks-svc-connector"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  identity {
    type = "SystemAssigned"
  }
}

# Grant MI access to target service (e.g. Key Vault)
resource "azurerm_role_assignment" "kv_access" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_databricks_access_connector.svc.identity[0].principal_id
}

# --- Service Credential ---
resource "databricks_credential" "svc_cred" {
  name = "azure-keyvault-cred"
  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.svc.id
  }
  purpose = "SERVICE"
  comment = "Access to Azure Key Vault"
}

resource "databricks_grants" "svc_cred" {
  credential = databricks_credential.svc_cred.id
  grant {
    principal  = "Data Engineers"
    privileges = ["ACCESS"]
  }
}
```

### GCP

```hcl
# --- Service Credential (Databricks generates the GCP SA) ---
resource "databricks_credential" "svc_cred" {
  name = "gcp-pubsub-cred"
  databricks_gcp_service_account {}
  purpose = "SERVICE"
  comment = "Access to GCP Pub/Sub"
}

# Grant the generated SA access to GCP Pub/Sub
resource "google_project_iam_member" "pubsub" {
  project = var.gcp_project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${databricks_credential.svc_cred.databricks_gcp_service_account[0].email}"
}

resource "databricks_grants" "svc_cred" {
  credential = databricks_credential.svc_cred.id
  grant {
    principal  = "Data Engineers"
    privileges = ["ACCESS"]
  }
}
```

### Workspace Binding (Isolation)

```hcl
resource "databricks_credential" "svc_cred" {
  name           = "prod-secrets-cred"
  aws_iam_role {
    role_arn = aws_iam_role.prod.arn
  }
  purpose        = "SERVICE"
  isolation_mode = "ISOLATION_MODE_ISOLATED"
}

resource "databricks_workspace_binding" "prod_only" {
  securable_name = databricks_credential.svc_cred.name
  securable_type = "credential"
  workspace_id   = var.prod_workspace_id
}
```

### Terraform Argument Reference

| Argument | Required | Description |
|---|---|---|
| `name` | Yes | Unique within the metastore. Change forces new resource. |
| `purpose` | Yes | `SERVICE` or `STORAGE` |
| `owner` | No | Username/groupname/SP application_id |
| `skip_validation` | No | Force save, suppress validation |
| `force_destroy` | No | Delete regardless of dependencies |
| `force_update` | No | Update regardless of dependents |
| `isolation_mode` | No | `ISOLATION_MODE_ISOLATED` or `ISOLATION_MODE_OPEN` |
| `comment` | No | Description |

**Cloud blocks** (mutually exclusive):

| Block | Cloud | Fields |
|---|---|---|
| `aws_iam_role` | AWS | `role_arn` (required) |
| `azure_managed_identity` | Azure | `access_connector_id` (required), `managed_identity_id` (optional for user-assigned MI) |
| `databricks_gcp_service_account` | GCP | Empty block; `email` is output-only |

---

## Python SDK

```python
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()

# Create (AWS example)
cred = w.credentials.create_credential(
    name="my-aws-cred",
    purpose="SERVICE",
    aws_iam_role={"role_arn": "arn:aws:iam::123456789012:role/my-role"},
)

# List service credentials
for c in w.credentials.list_credentials(purpose="SERVICE"):
    print(c.name, c.credential_id)

# Get
cred = w.credentials.get_credential("my-aws-cred")

# Generate temporary credentials (for external callers)
temp = w.credentials.generate_temporary_service_credential(
    credential_name="my-aws-cred"
)

# Delete
w.credentials.delete_credential("my-aws-cred", force=True)
```

---

## Supported Services (Not Exhaustive)

Service credentials work with **any cloud service** that accepts the respective cloud identity. Documented examples:

| Cloud | Documented Services | Credential Type in Code |
|---|---|---|
| AWS | Secrets Manager, Glue, S3, Bedrock, DynamoDB, Lake Formation | `botocore.session.Session` / `AWSCredentialsProvider` |
| Azure | Key Vault, OpenAI, Cosmos DB, SQL Database, Event Hubs, Service Bus | `TokenCredential` |
| GCP | Pub/Sub, GCS, BigQuery, Vertex AI, Spanner, Cloud Functions | `google.auth.credentials.Credentials` / `GoogleCredentials` |

---

## GCP BigQuery Worked Example (Battle-Tested 2026-03-26)

### GCP API Enablement Impact by Service

The service account that Unity Catalog generates for a GCP service credential runs in a Databricks-managed project. Some GCP APIs check the **caller's project** for API enablement, not just the resource project. This table shows which services are affected.

| Service | Checks Caller's Project? | Quota-project config needed? | Impact |
|---|---|---|---|
| **BigQuery** | Yes | `quota_project_id` + `serviceUsageConsumer` | **High** |
| **Cloud Storage (GCS)** | Yes | Same (mandatory for Requester Pays) | **High** |
| **Cloud SQL Admin API** | Yes | Same | **Medium** |
| Pub/Sub | No | No | Low |
| Vertex AI | No | No | Low |
| Spanner | No | No | Low |
| Secret Manager | No | No | Low |
| Cloud Functions | No | No | Low |
| Firestore / Datastore | No | No | Low |
| Bigtable | No | No | Low |
| Cloud KMS | No | No | Low |

**Pattern**: "Analytics/management plane" APIs (BigQuery, GCS, Cloud SQL Admin) check the caller's project. "Resource-centric" APIs (Pub/Sub, Secret Manager, Spanner) only check the resource project. This is why the Databricks docs use Pub/Sub as the example: it works without extra quota-project configuration.

** for affected services** (all three steps required):
1. Grant `roles/serviceusage.serviceUsageConsumer` to the SA on the customer's project
2. Set `quota_project_id` via `client_options` or the `x-goog-user-project` HTTP header
3. Monkey-patch `with_quota_project()` on `GCPCustomCredentials` (see below)

### Classic Cluster (Works)

Requires: DBR 16.4 LTS, `SINGLE_USER` access mode, `google-cloud-bigquery` pip library.

```python
from google.cloud import bigquery

PROJECT = "my-gcp-project"
credentials = dbutils.credentials.getServiceCredentialsProvider("my-bq-cred")

# CRITICAL: Patch with_quota_project ( in GCPCustomCredentials)
type(credentials).with_quota_project = lambda self, qp: setattr(self, '_quota_project_id', qp) or self

# CRITICAL: Set quota_project_id to route API calls through YOUR project
# (not the Databricks UC regional project where the SA lives)
client = bigquery.Client(
    project=PROJECT,
    credentials=credentials,
    client_options={"quota_project_id": PROJECT},
    location="us-central1",  # match your dataset location
)

# Read/write BigQuery as normal
df = client.query("SELECT * FROM `my-project.my_dataset.my_table`").to_dataframe()
```

**GCP IAM roles required** on the Databricks-generated SA:
- `roles/bigquery.dataEditor` (read/write tables)
- `roles/bigquery.jobUser` (run queries)
- `roles/serviceusage.serviceUsageConsumer` (route API calls through your project)

### Serverless Compute

**UC Service Credentials**: Blocked. `getServiceCredentialsProvider()` raises `Unsupported cloud provider: gcp` on serverless. The serverless runtime only implements AWS and Azure credential providers. .

**Spark BQ Connector + SA Key**: Reads work, writes blocked. The Spark BQ connector is pre-installed on serverless and accepts Base64-encoded SA keys from Databricks Secrets. DML (writes) are not allowed for the `bigquery` data source on serverless.

```python
import base64

# SA key from Databricks Secrets → Base64 → connector (no temp files)
sa_key = dbutils.secrets.get("my-scope", "bq-sa-key")
BQ_CREDS = base64.b64encode(sa_key.encode()).decode()

# Read works
df = spark.read.format("bigquery") \
    .option("credentials", BQ_CREDS) \
    .option("parentProject", "my-gcp-project") \
    .option("project", "my-gcp-project") \
    .load("my_dataset.my_table")

# Write blocked on serverless (DML not allowed for bigquery data source)
```

**GCP IAM roles required** on the SA for reads:
- `roles/bigquery.jobUser` (run queries)
- `roles/bigquery.dataViewer` (read tables)
- `roles/bigquery.readSessionUser` (Storage Read API, used by the Spark connector)

### BigQuery Access: Decision Tree

| Approach | Auth | UC Governed | Compute | Read | Write |
|---|---|---|---|---|---|
| **Lakehouse Federation** | SA key in UC Connection | Yes | SQL Warehouse, Serverless, Classic | Yes (SQL) | No |
| **UC Service Credential + Python SDK** | UC-managed GCP SA | Yes | Classic only (DBR 16.2+) | Yes | Yes |
| **Spark BQ Connector + SA Key** | Base64 SA key from Secrets | No | Classic, Serverless | Yes | Classic only |

- SQL from warehouse or serverless? → **Lakehouse Federation**
- Spark DataFrame reads on serverless? → **Spark BQ Connector + SA key**
- Per-user governed read/write? → **UC Service Credential** (classic cluster)
- Write back to BQ? → **UC Service Credential** or **Spark Connector** (classic only)
- Multiple GCP services in one workflow? → **UC Service Credential** (only option that generalizes beyond BQ)

### Cluster Requirements

| Requirement | Details |
|---|---|
| Databricks Runtime | 16.2+ (16.4 LTS recommended) |
| Access mode | `SINGLE_USER` or `SHARED` (UC-enabled). Legacy "No Isolation" mode fails with "Access denied to clusters that don't have Unity Catalog enabled" |
| Spark conf (some workspaces) | `spark.databricks.unityCatalog.enableServiceCredentials=true` may be required if the workspace backend hasn't set it |

---

## Gotchas

1. **Not for storage**: Service credentials are for services, not for UC managed/external storage locations. Use storage credentials for that.
2. **No CREATE SQL**: You cannot `CREATE SERVICE CREDENTIAL` via SQL. Use Catalog Explorer, REST API, or Terraform.
3. **DBR version matters**: Code usage requires DBR 16.2+. DBR 16.1 and below support Python only (no Scala). SQL warehouses only support service credentials in batch UC Python UDFs.
4. **Serverless has no default cred**: `DATABRICKS_DEFAULT_SERVICE_CREDENTIAL_NAME` env var is  on serverless compute or SQL warehouses.
5. **GCP serverless **: `getServiceCredentialsProvider()` raises `Unsupported cloud provider: gcp` on serverless compute. The serverless runtime only has AWS and Azure handlers (as of March 2026). .
6. **AWS self-assumption enforced**: Since September 2024, new service credentials require self-assuming IAM roles. Since January 2025, existing non-self-assuming credentials are disabled.
7. **Azure SP restriction**: Service principals (both Azure Databricks and Entra ID) must have the **account admin** role to create a service credential with managed identity.
8. **Azure: MI over SP**: Managed identities are strongly recommended over service principals. MIs can access network-rule-protected services and eliminate secret rotation.
9. **GCP SA is generated**: You don't bring your own SA on GCP. Databricks generates one. Use the email output to grant IAM roles.
10. **GCP API enablement checks the caller's project**: The service account Unity Catalog generates runs in a Databricks-managed project, and some Google APIs (BigQuery, Cloud Storage, Cloud SQL Admin) check that caller project for API enablement, not just the resource project. To route enablement checks through your own project, set the `x-goog-user-project` header or `quota_project_id` as shown below.
11. **GCP quota project**: Set `client_options={"quota_project_id": YOUR_PROJECT}` and grant `roles/serviceusage.serviceUsageConsumer` to the service account on your project. This routes API enablement checks and rate limits through your project. Without it, you get `403: API has not been used in project XXXXXX`.
12. **`with_quota_project()` needs a manual patch**: `GCPCustomCredentials` does not implement `with_quota_project()` correctly (it fails with `unexpected keyword argument 'refresh_token'`). Patch it at runtime with `type(credentials).with_quota_project = lambda self, qp: setattr(self, '_quota_project_id', qp) or self`.
13. **Isolate GCP rate limits with a quota project**: Calls that route through the Databricks-managed project can share regional API rate limits. Setting `quota_project_id` to your own project (gotcha #11) routes both enablement checks and rate limits through your project instead.
14. **GCP scopes required for manual refresh**: If calling `credentials.refresh()` manually (e.g., for REST API usage without the SDK), you must set `credentials._scopes` first or the UC temporary-credentials API returns `missing gcp_options`.
15. **UC-enabled cluster required**: Clusters must use `data_security_mode: SINGLE_USER` or `SHARED`. Legacy access modes fail with "Access denied to clusters that don't have Unity Catalog enabled".
16. **`enableServiceCredentials` spark conf**: Some workspaces require `spark.databricks.unityCatalog.enableServiceCredentials=true` set at the cluster level. This is a workspace-backend flag that should be set automatically on GA workspaces, but may be missing on older or VPC-SC workspaces.
17. **DBR language support constraint**: DBR 16.1 and below support Python-only code usage. Multi-language support (Scala, R, SQL UDFs) requires DBR 16.2 or later. For classic clusters on older DBR, use Python SDK exclusively.
17. **UDFs use different API**: Inside UDFs, use `databricks.service_credentials.getServiceCredentialsProvider()`, not `dbutils.credentials.getServiceCredentialsProvider()`.
18. **Deprecated INFORMATION_SCHEMA views**: Use `INFORMATION_SCHEMA.CREDENTIALS` and `INFORMATION_SCHEMA.CREDENTIAL_PRIVILEGES`, not the deprecated `STORAGE_CREDENTIALS` / `STORAGE_CREDENTIAL_PRIVILEGES`.
19. **Audit gaps**: Some audit events for service credential actions may not appear in `system.access.audit`.
20. **GCP Scala note**: Google Cloud SDK Maven dependencies require a shaded version of Guava to avoid conflicts.
21. **`google-cloud-bigquery` crashes serverless**: Installing the BQ Python SDK on serverless compute crashes the Python kernel due to dependency conflicts with core packages (grpcio/protobuf).
22. **Serverless BQ writes blocked**: The Spark BQ connector is pre-installed on serverless and reads work with SA key auth (`credentials` option + Base64-encoded key from Secrets). However, writes are blocked: `bigquery` is not in the DML-allowed data source list for serverless compute. Only `csv, json, avro, delta, kafka, parquet, orc, text, unity_catalog, binaryFile, xml, excel, simplescan, iceberg` support DML on serverless.
23. **Spark BQ connector IAM for reads**: The connector uses the BigQuery Storage Read API, which requires `roles/bigquery.readSessionUser` in addition to `roles/bigquery.dataViewer` and `roles/bigquery.jobUser`. Missing this role causes `PERMISSION_DENIED: bigquery.readsessions.create`.

---

## Related

- [`governance/unity-catalog.md`](unity-catalog.md) — UC namespaces, privileges, grants
- [`governance/http-connections.md`](http-connections.md) — UC HTTP connections (alternative for REST API access)
- [`auth/overview.md`](../auth/overview.md) — OBO vs M2M vs PAT decision tree
- [`ai/ai-gateway.md`](../ai/ai-gateway.md) — Service credentials for external model endpoints (Bedrock, etc.)
- [`ai/model-serving.md`](../ai/model-serving.md) — External model endpoints that reference service credentials
