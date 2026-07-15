<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: governance/http-connections.md, governance/service-credentials.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/query-federation/http
    - https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-services/service-credentials
  This file is auto-prepared and human-reviewed before publish.
-->

# Unity Catalog Connections: HTTP & Service Credentials

> **Pillar 4**: Governing external service access

---

## The Business Challenge

Your AI agents and pipelines need to reach outside the lakehouse: SaaS APIs, partner systems, external MCP servers, and native cloud services (secrets managers, key vaults, pub/sub, model endpoints). Every one of those calls raises the same two governance questions:

1. **Who controls the credentials?** If API keys or cloud identities live in environment variables or application code, anyone with repo access has them, and rotation means redeploying every consumer.
2. **Who decides which agent or user can reach which service?** Without centralized authorization, any workload that can reach the network can call any external endpoint.

Unity Catalog answers both with two complementary securable types:

- **HTTP Connections** govern access to external HTTP services — REST APIs, external MCP servers, SaaS platforms.
- **Service Credentials** govern access to native cloud services — AWS Secrets Manager, Azure Key Vault, GCP Pub/Sub, and similar — by wrapping a cloud identity (IAM role, managed identity, service account) as a UC securable.

Both make credential storage and access authorization a Unity Catalog concern instead of an application concern.

---

## Part 1 — UC HTTP Connections

HTTP connections are available wherever Model Serving is supported (see [Model serving region availability](https://learn.microsoft.com/en-us/azure/databricks/resources/feature-region-support#azure-model-serving)). Compute must be Databricks Runtime 15.4 LTS+ (Standard or Dedicated access mode) or a Pro/Serverless SQL warehouse on version 2023.40+.

### How It Works

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

The app never holds the credential. Databricks injects it at proxy time. Revoke `USE CONNECTION` and access stops instantly — no redeploy, no code change.

---

### Five Authentication Methods

The key question for any method: **what identity does the external service see?**

| Method | Databricks Identity | External Service Identity | Credential Lifecycle | Best For |
|---|---|---|---|---|
| **Bearer Token** | Per `current_user()` | Shared (one static token) | Manual rotation | Simple APIs with static keys |
| **OAuth M2M** | Per `current_user()` | Shared (service/app credentials) | Auto-refresh | Service-to-service, no user context needed |
| **OAuth U2M Shared** | Per `current_user()` | Shared (one user's OAuth token) | Auto-refresh | OAuth services without M2M support |
| **OAuth U2M Per User** | Per `current_user()` | Per user (individual OAuth token) | Auto-refresh per user | User-scoped data (personal Drive, Gmail, repos) |
| **Dynamic Client Registration (DCR)** | Per `current_user()` | Per user (individual OAuth token) | Auto-refresh per user | MCP servers that support RFC 7591 client registration |

All five methods enforce `USE CONNECTION` on the Databricks side. What differs is which identity the external service sees, and how much manual OAuth app registration is required up front.

### Choosing the Right Method

```
Need per-user identity at the external service?
  |
  +-- Yes --> Does the external service support OAuth Dynamic Client Registration (RFC 7591)?
  |             +-- Yes --> Dynamic Client Registration (recommended: zero manual OAuth app setup)
  |             +-- No  --> Does it support standard OAuth authorization code flow?
  |                           +-- Yes --> OAuth U2M Per User
  |                           +-- No  --> Consider app-level auth instead of a UC connection
  |
  +-- No (shared access is fine)
        +-- External service supports OAuth client_credentials? --> OAuth M2M (recommended)
        +-- OAuth but no client_credentials grant?              --> OAuth U2M Shared
        +-- Static API key only?                                --> Bearer Token
```

---

### Bearer Token

Stores a static API key or PAT. All callers share the same credential.

- **Setup**: Provide `host` and `bearerToken` when creating the connection
- **Rotation**: Manual — update the connection when the token expires
- **External identity**: The entity the token was issued to (shared across all callers)

```bash
databricks connections create \
  --connection-type HTTP \
  --name my_api_conn \
  --options '{
    "host": "https://api.example.com",
    "httpPath": "/v1",
    "bearerToken": "<api-key>"
  }'
```

Simple but manual: expiration requires updating the connection by hand. Prefer an OAuth method when the external service supports one.

---

### OAuth M2M (Client Credentials)

Service-to-service authentication. Databricks exchanges client credentials for an access token automatically.

- **Setup**: Provide `clientId`, `clientSecret`, `tokenUrl`, and `scope`
- **Rotation**: Automatic — Databricks refreshes the token before expiration
- **External identity**: The OAuth client application (shared across all callers)

```bash
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
```

Recommended over Bearer Token whenever the external service supports OAuth — no manual rotation, no expiration surprises.

---

### OAuth U2M Shared

One user authorizes the connection via browser-based OAuth consent. All callers use that user's refresh token.

- **Setup**: Provide `clientId`, `clientSecret`, `authUrl`, `tokenUrl`, `scope`. One user completes "Sign in with HTTP" to authorize.
- **Rotation**: Automatic via refresh token
- **External identity**: The authorizing user (shared across all callers)
- **Design note**: Because one user's authorization backs every caller, choose OAuth M2M instead whenever the external service supports the `client_credentials` grant.

**Redirect URL**: Allowlist `<databricks-workspace-url>/login/oauth/http.html` with the external OAuth provider.

---

### OAuth U2M Per User

Each user authenticates separately with the external service — true per-user identity propagation end to end.

- **Setup**: Same fields as U2M Shared, but each user completes their own OAuth consent flow on first use
- **Rotation**: Per-user refresh tokens, managed automatically
- **External identity**: The individual user (each caller has their own token)

This is the method that provides true end-to-end per-user access control across both Databricks and the external service. Each user sees only their own data (their Drive files, their Gmail, their repositories).

**Supported external services** (as of 2026-03): Google (Drive, Docs, Gmail, Calendar, Tasks), GitHub, Glean, SharePoint, and custom OAuth services that implement the standard authorization code flow.

**Redirect URL**: The external OAuth provider must allowlist `<databricks-workspace-url>/login/oauth/http.html`.

---

### Dynamic Client Registration (DCR)

DCR uses [RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591) so Databricks can discover OAuth endpoints and register a client automatically. You provide only the host URL — Databricks discovers the authorization server, registers OAuth credentials, and manages per-user consent flows for you.

```json
{
  "host": "https://api.example.com",
  "base_path": "/mcp",
  "oauth_scope": "read write"
}
```

| Advantages | Requirements |
|---|---|
| Zero manual OAuth app registration | External service must implement OAuth 2.0 DCR (RFC 7591) |
| Per-user identity at the external service | |
| Ideal for MCP servers that support DCR | |

DCR is the recommended authentication method for MCP servers that support it — Databricks manages the OAuth client on your behalf.

---

### Managed OAuth Providers

For a set of common providers, Databricks manages the OAuth client registration and credentials for you — no OAuth app to register at all. Select **OAuth User to Machine Per User** and choose the provider by name:

| Provider | Default Base Path | Scopes | Use Case |
|---|---|---|---|
| **Glean MCP** | `/mcp/default` | `mcp` | Enterprise search, chat, documents, agent tools |
| **GitHub MCP** | (default) | `repo read:project read:org` | Repositories, organizations, project data |
| **Atlassian MCP** | (default) | `read:jira-work read:jira-user read:confluence-content.all offline_access` | Issue tracking and wiki content |
| **Slack MCP** | (default) | `search:read.public channels:history users:read` (+more) | Messages, files, channels, direct messages |

If your identity provider requires an explicit allowlist, add the redirect URI for your cloud:

| Cloud | Redirect URI |
|---|---|
| AWS | `https://oregon.cloud.databricks.com/api/2.0/http/oauth/redirect` |
| Azure | `https://westus.azuredatabricks.net/api/2.0/http/oauth/redirect` |
| GCP | `https://us-central1.gcp.databricks.com/api/2.0/http/oauth/redirect` |

For GitHub, Glean, Atlassian, and Slack, this removes the OAuth app registration and token-management steps entirely — select the provider and Databricks handles the rest.

---

### Setup: OAuth Provider Configuration

Using Google as an illustrative example for U2M connections:

**1. External OAuth provider (Google Cloud Console)**

- Create an **OAuth client ID** (Web application type)
- Add the Databricks redirect URI to **Authorized redirect URIs**: `https://<workspace-url>/login/oauth/http.html`
- Enable the APIs matching your requested scopes (Drive API, Docs API, Gmail API, etc.)
- Configure the **OAuth consent screen** (Internal for Google Workspace, External for personal accounts)

**2. Databricks** (Catalog Explorer > Connections > Create)

- Connection type: **HTTP**
- Host: `https://www.googleapis.com`
- Authorization endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
- Token endpoint: `https://oauth2.googleapis.com/token`
- OAuth scope: `offline_access https://www.googleapis.com/auth/drive ...`
- Enter Client ID and Client Secret, then click **Sign in with HTTP** to complete consent

**3. Common setup errors**

| Error | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | Redirect URI in the provider console does not match what Databricks sends | Copy the exact URI from the error details into the provider console (no trailing slash, no spaces) |
| `admin_policy_enforced` | Org admin policy blocks unapproved third-party OAuth apps | Ask an admin to allowlist the OAuth Client ID in the provider's admin console |
| `invalid_scope` | Requested scope is not enabled on the OAuth project | Enable the corresponding API/scope in the provider console |

The `offline_access` scope is required to obtain a refresh token. Without it, Databricks cannot auto-refresh the access token after it expires (commonly around one hour).

---

### Provider Prerequisites (Service-Agnostic)

For any external service to work with the U2M flow, it needs to meet six requirements — this applies whether the provider is Google, Salesforce, Microsoft, GitHub, or a custom OAuth service.

| Requirement | Detail |
|---|---|
| **OAuth 2.0 Authorization Code Grant** | RFC 6749 Section 4.1: user is redirected to the authorization endpoint, grants consent, provider redirects back with a code |
| **Refresh token support** | Provider must issue a `refresh_token`. Some require a specific scope: Google (`offline_access`), Microsoft (`offline_access`), Salesforce (`refresh_token`) |
| **Configurable redirect URIs** | Provider must allow registering `<workspace-url>/login/oauth/http.html` as a custom redirect URI |
| **Confidential client support** | Provider must support Client ID + Client Secret clients (not PKCE-only public clients) |
| **Standard token endpoint** | Must accept `grant_type=authorization_code` and `grant_type=refresh_token` |
| **HTTPS endpoints** | All authorization and token endpoints must be HTTPS |

**Credential exchange method** — providers differ in how they accept client credentials during token exchange:

| Method | How credentials are sent | Example provider |
|---|---|---|
| `header_and_body` (default) | Both Authorization header and request body | Google, most providers |
| `body_only` | Request body only | Some custom OAuth servers |
| `header_only` | Authorization header only | Okta |

**Quick checklist** before attempting a U2M connection to any provider: does it expose an authorization endpoint and a token endpoint, can you create a Client ID + Secret, can you register a custom redirect URI, does it issue refresh tokens, and does it use standard OAuth 2.0 token-exchange parameters? If all six are yes, it works with UC HTTP connections U2M.

---

### Creating and Managing Connections

**Via UI**: Catalog Explorer → **Connections** → **Create connection** → type **HTTP** → set name, host, base path, authentication method, and whether it is an MCP connection.

**Via SQL**:

```sql
-- Bearer token
CREATE CONNECTION my_api_conn TYPE HTTP
OPTIONS (
  host 'https://api.example.com',
  port '443',
  base_path '/v1',
  bearer_token secret ('<secret-scope>', '<secret-key>')  -- reference a secret, not plaintext
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

OAuth U2M Shared must be created through the Catalog Explorer UI (not SQL), since it requires an interactive consent step.

**Via Python SDK**:

```python
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()
conn = w.connections.create(
    name="my_api_conn",
    connection_type="HTTP",
    options={"host": "https://api.example.com", "httpPath": "/v1", "bearerToken": "<api-key>"},
)
```

**Listing, updating, deleting**:

```bash
databricks connections list
databricks connections update my_api_conn --options '{"host": "https://api.example.com", "bearerToken": "<new-token>"}'
databricks connections delete my_api_conn
```

Deleting a connection takes effect immediately for every agent and query that references it, including any external MCP proxy URL built on it — plan credential rotation and connection retirement accordingly.

---

### Calling External Services

**Proxy endpoint (recommended for new integrations)**

The proxy endpoint forwards requests to the external service while injecting the stored credential. Your code authenticates to Databricks; Databricks handles the external authentication.

```
https://<workspace-hostname>/api/2.0/unity-catalog/connections/<connection-name>/proxy[/<sub-path>]
```

The final external URL is constructed as `{connection host}{base_path}{sub-path}`.

```bash
curl -X POST \
  "https://<workspace>/api/2.0/unity-catalog/connections/slack_connection/proxy/chat.postMessage" \
  -H "Authorization: Bearer <databricks-token>" \
  -H "Content-Type: application/json" \
  -d '{"channel": "C123456", "text": "Hello!"}'
```

Supported methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. `Authorization`, `Cookie`, and `X-Databricks-*` headers are stripped before the request is forwarded, so a client can never leak its own Databricks token to the external service. All other headers pass through unchanged.

```python
from databricks_openai import DatabricksOpenAI
from databricks.sdk import WorkspaceClient

w = WorkspaceClient()
client = DatabricksOpenAI(
    workspace_client=w,
    base_url=f"{w.config.host}/api/2.0/unity-catalog/connections/openai_connection/proxy/",
)
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello!"}],
)
```

**`http_request()` SQL function (legacy path)**

`http_request()` remains available for SQL-based calls, but new integrations should use the proxy endpoint above.

```sql
SELECT http_request(
    conn => 'my_api_conn',
    method => 'GET',
    path => '/customers/12345'
) AS response;
```

For Dynamic Client Registration and OAuth U2M Per User connections, call the proxy endpoint or the Python SDK — `http_request()` in SQL supports the other three authentication methods:

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

`http_request()` (SQL and SDK) is rate limited and designed for interactive/agent use rather than high-volume batch calls. For large row counts, batch IDs and call a bulk API endpoint, or use the proxy endpoint with the provider's own SDK.

---

### Query Federation via HTTP

HTTP connections also support querying external REST APIs as part of SQL, useful for enrichment patterns:

```sql
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

Since `http_request()` issues one HTTP call per row, batch IDs into a bulk API call for large datasets, or pre-materialize the external data into a UC table.

---

### Network Security for HTTP Connections

**Private Link**: for external services inside your VNet/VPC, configure Private Link so traffic stays on a private connection. See [Configure private connectivity to resources in your VNet](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/pl-to-internal-network).

**IP allowlisting**: workspaces created before March 2026 may have firewall rules that reference control-plane IPs rather than serverless IPs. Update allowlists to the serverless IP ranges by May 30, 2026 to keep connectivity uninterrupted — see [Migrate to serverless routing for HTTP connections](https://learn.microsoft.com/en-us/azure/databricks/query-federation/http-migration).

---

### USE CONNECTION Governance

`USE CONNECTION` is the UC privilege that controls access to HTTP connections.

```sql
-- Grant to a group
GRANT USE CONNECTION ON CONNECTION my_api_conn TO `data_team`;

-- Grant to a service principal (for automated agents)
GRANT USE CONNECTION ON CONNECTION my_api_conn TO `<service-principal-application-id>`;

-- Revoke
REVOKE USE CONNECTION ON CONNECTION my_api_conn FROM `former_employee@example.com`;

-- View grants
SHOW GRANTS ON CONNECTION my_api_conn;
```

| Behavior | Detail |
|---|---|
| **Connection owner** | Has implicit `USE CONNECTION` — cannot be revoked |
| **Transfer ownership** | `ALTER CONNECTION my_api_conn SET OWNER TO \`new_owner@example.com\`` |
| **Inheritance** | `USE CONNECTION` does not inherit from catalog/schema grants — it is a standalone privilege |
| **Audit** | Every `USE CONNECTION` check is logged in `system.access.audit` |

Combined with Serverless Network Policies (SNP), this gives defense in depth: SNP defines which external destinations are reachable at the network layer, and `USE CONNECTION` controls which identities can authenticate to those destinations.

---

### Gotchas — HTTP Connections

| Issue | Detail |
|---|---|
| **Bearer token expiration** | Tokens stored in connections expire; rotate manually, or use an OAuth method for auto-refresh |
| **Connection name is immutable** | It becomes part of the MCP proxy URL — choose a stable, descriptive name at creation time |
| **Owner has irrevocable `USE CONNECTION`** | Transfer ownership via `ALTER CONNECTION ... SET OWNER TO ...` if the creator should lose access |
| **`isMcpConnection` cannot be changed after creation** | Delete and recreate the connection if you need to change it |
| **`unity-catalog` scope required** | The calling token must include the `unity-catalog` scope to reach the MCP proxy |
| **`offline_access` scope missing** | Without a refresh token, the connection works briefly then fails silently — always request the refresh-token scope for the provider |
| **IP allowlist migration** | Workspaces created before March 2026 should migrate firewall rules from control-plane to serverless IPs by May 30, 2026 |

---

## Part 2 — Service Credentials

A **service credential** is a Unity Catalog securable that wraps a cloud identity — an AWS IAM role, Azure managed identity, or GCP service account — so users and agents get governed access to native cloud services. Where storage credentials govern access to managed/external storage locations (S3, ADLS, GCS), service credentials govern access to everything else: Secrets Manager, Key Vault, Pub/Sub, Glue, Bedrock, and similar service APIs. Access is controlled per user, group, or service principal via `GRANT ACCESS` — not tied to a specific compute resource.

### When to Use What

| Need | Use |
|---|---|
| Access to UC managed/external storage locations | **Storage credential** |
| Access to external cloud services (APIs, secrets, queues) | **Service credential** |
| Lakehouse Federation connection to an external database | **Service credential** with `CREATE CONNECTION` grant |
| AI Gateway external model endpoint (e.g., Bedrock) | **Service credential** referenced in the endpoint config |

### Cloud Comparison

| Aspect | AWS | Azure | GCP |
|---|---|---|---|
| **Cloud identity** | Customer-created IAM role | Managed identity via Access Connector | Databricks-generated GCP service account |
| **Setup flow** | Create IAM role, register in Databricks, update trust policy with the returned external ID | Create Access Connector + managed identity, grant it roles on the target service, register in Databricks | Register the credential in Databricks, then grant the generated service account roles in the GCP console |
| **Self-referencing requirement** | Yes — the role trusts itself (required since September 2024) | N/A | N/A |
| **Trust mechanism** | Cross-account `sts:AssumeRole` to the UC master role, gated by an external ID | Access Connector resource ID | Databricks-managed service account; no key management overhead |
| **Credential type in code** | `botocore.session.Session` / `AWSCredentialsProvider` | `TokenCredential` (Azure SDK) | `google.auth.credentials.Credentials` / `GoogleCredentials` |
| **Terraform block** | `aws_iam_role { role_arn = "..." }` | `azure_managed_identity { access_connector_id = "..." }` | `databricks_gcp_service_account {}` (empty; the SA email is an output) |

### Prerequisites

- Unity Catalog-enabled workspace
- `CREATE SERVICE CREDENTIAL` privilege on the metastore (account admins, metastore admins, and workspace admins have this by default)
- Databricks Runtime 16.2+ for full code usage across Python and Scala; 15.4 LTS+ supports Python only

On Azure, service principals must hold the account admin role to create a service credential backed by a managed identity — this cannot be delegated to a service principal alone.

### Creating a Service Credential

**AWS**

1. **Create a self-assuming IAM role.** Every service credential's role must trust itself in its own trust policy (enforced since September 2024):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": ["arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"]},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"sts:ExternalId": "0000"}}
  }]
}
```

2. **Attach a permissions policy scoped to the target service** — for example, Secrets Manager:

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

3. **Register the role in Databricks**: Catalog Explorer → External Data → Credentials → Create credential → Service Credential. Enter the role ARN and note the generated external ID.

4. **Update the trust policy** with the real external ID and add self-assumption for the role's own ARN.

5. **Validate**: select the credential and confirm the self-assume-role check passes (typically one to two minutes).

**Azure**

1. Create an Azure Databricks Access Connector and assign its managed identity the required RBAC roles on the target service (Contributor or higher on the access connector resource is needed to configure it). A system- or user-assigned managed identity is recommended over a service principal — it avoids secret rotation and can reach network-restricted services.
2. Register in Databricks: Catalog Explorer → External Data → Credentials → Create credential → Service Credential, entering the access connector resource ID (and optional user-assigned managed identity ID).

**GCP**

1. Create the credential in Databricks: Catalog Explorer → External Data → Credentials → Create credential → Service Credential. Databricks generates a GCP service account automatically (`<id>@<project>.iam.gserviceaccount.com`).
2. Grant that generated service account the required IAM roles on the target GCP service in the GCP console.

### SQL Commands

```sql
SHOW SERVICE CREDENTIALS;
DESCRIBE SERVICE CREDENTIAL <credential-name>;

GRANT ACCESS ON SERVICE CREDENTIAL <credential-name> TO <principal>;
GRANT CREATE CONNECTION ON SERVICE CREDENTIAL <credential-name> TO <principal>;
SHOW GRANTS [<principal>] ON SERVICE CREDENTIAL <credential-name>;
REVOKE ACCESS ON SERVICE CREDENTIAL <credential-name> FROM <principal>;

ALTER SERVICE CREDENTIAL <credential-name> OWNER TO <principal>;
ALTER SERVICE CREDENTIAL <credential-name> RENAME TO <new-name>;
DROP SERVICE CREDENTIAL [IF EXISTS] <credential-name>;
```

| Privilege | Grants |
|---|---|
| `ACCESS` | Use the credential to access external cloud services |
| `CREATE CONNECTION` | Create Lakehouse Federation connections using this credential |

Service credentials cannot be created via SQL — use Catalog Explorer, the REST API, or Terraform for creation; SQL manages grants and lifecycle after that.

### Using Service Credentials in Code

```python
# AWS — boto3
import boto3
boto3_session = boto3.Session(
    botocore_session=dbutils.credentials.getServiceCredentialsProvider('my-aws-cred'),
    region_name='us-west-2'
)
sm = boto3_session.client('secretsmanager')
secret = sm.get_secret_value(SecretId='my-secret')
```

```python
# Azure — Azure SDK
from azure.keyvault.secrets import SecretClient
credential = dbutils.credentials.getServiceCredentialsProvider('my-azure-cred')
client = SecretClient(vault_url="https://my-vault.vault.azure.net/", credential=credential)
secret = client.get_secret("my-secret")
```

```python
# GCP — google-cloud SDK
from google.cloud import pubsub_v1
credentials = dbutils.credentials.getServiceCredentialsProvider('my-gcp-cred')
publisher = pubsub_v1.PublisherClient(credentials=credentials)
topic_path = publisher.topic_path('my-project', 'my-topic')
future = publisher.publish(topic_path, b"Hello from Databricks")
```

Scala works the same way via `dbutils.credentials.getServiceCredentialsProvider(...)`, cast to the SDK's expected credential type (`AWSCredentialsProvider`, `TokenCredential`, or `GoogleCredentials`).

**Inside UDFs**, use the dedicated UDF-safe accessor instead:

```python
from databricks.service_credentials import getServiceCredentialsProvider
cred = getServiceCredentialsProvider('my-cred')
```

**Default service credential (classic compute):** set an environment variable at the cluster level (Advanced → Spark tab → Environment variables):

```
DATABRICKS_DEFAULT_SERVICE_CREDENTIAL_NAME=my-cred
```

With this set, SDK clients pick up the credential automatically without naming it explicitly. This environment variable applies to classic compute; on serverless compute or SQL warehouses, pass the credential explicitly via `getServiceCredentialsProvider()`.

### Terraform

The unified resource is `databricks_credential` with `purpose = "SERVICE"` (there is no separate service-credential resource type).

```hcl
# AWS
resource "aws_iam_role" "svc_cred" {
  name               = "databricks-svc-cred"
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json
}

data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  aws_account_id = var.aws_account_id
  role_name      = aws_iam_role.svc_cred.name
  external_id    = databricks_credential.svc_cred.aws_iam_role[0].external_id
}

resource "databricks_credential" "svc_cred" {
  name    = "aws-secrets-cred"
  aws_iam_role { role_arn = aws_iam_role.svc_cred.arn }
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

```hcl
# Azure
resource "azurerm_databricks_access_connector" "svc" {
  name                = "databricks-svc-connector"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "kv_access" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_databricks_access_connector.svc.identity[0].principal_id
}

resource "databricks_credential" "svc_cred" {
  name    = "azure-keyvault-cred"
  azure_managed_identity { access_connector_id = azurerm_databricks_access_connector.svc.id }
  purpose = "SERVICE"
  comment = "Access to Azure Key Vault"
}
```

```hcl
# GCP
resource "databricks_credential" "svc_cred" {
  name    = "gcp-pubsub-cred"
  databricks_gcp_service_account {}
  purpose = "SERVICE"
  comment = "Access to GCP Pub/Sub"
}

resource "google_project_iam_member" "pubsub" {
  project = var.gcp_project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${databricks_credential.svc_cred.databricks_gcp_service_account[0].email}"
}
```

**Workspace binding (isolation):**

```hcl
resource "databricks_credential" "svc_cred" {
  name           = "prod-secrets-cred"
  aws_iam_role   { role_arn = aws_iam_role.prod.arn }
  purpose        = "SERVICE"
  isolation_mode = "ISOLATION_MODE_ISOLATED"
}

resource "databricks_workspace_binding" "prod_only" {
  securable_name = databricks_credential.svc_cred.name
  securable_type = "credential"
  workspace_id   = var.prod_workspace_id
}
```

| Argument | Required | Description |
|---|---|---|
| `name` | Yes | Unique within the metastore; changing it forces a new resource |
| `purpose` | Yes | `SERVICE` or `STORAGE` |
| `owner` | No | Username, group name, or service principal application ID |
| `isolation_mode` | No | `ISOLATION_MODE_ISOLATED` or `ISOLATION_MODE_OPEN` |
| `comment` | No | Description |

Cloud blocks (`aws_iam_role`, `azure_managed_identity`, `databricks_gcp_service_account`) are mutually exclusive — use the one matching your cloud.

### Python SDK

```python
from databricks.sdk import WorkspaceClient
w = WorkspaceClient()

cred = w.credentials.create_credential(
    name="my-aws-cred",
    purpose="SERVICE",
    aws_iam_role={"role_arn": "arn:aws:iam::123456789012:role/my-role"},
)

for c in w.credentials.list_credentials(purpose="SERVICE"):
    print(c.name, c.credential_id)

cred = w.credentials.get_credential("my-aws-cred")
temp = w.credentials.generate_temporary_service_credential(credential_name="my-aws-cred")
w.credentials.delete_credential("my-aws-cred", force=True)
```

### Supported Services (illustrative, not exhaustive)

| Cloud | Example services | Credential type in code |
|---|---|---|
| AWS | Secrets Manager, Glue, S3, Bedrock, DynamoDB, Lake Formation | `botocore.session.Session` / `AWSCredentialsProvider` |
| Azure | Key Vault, Azure OpenAI, Cosmos DB, SQL Database, Event Hubs, Service Bus | `TokenCredential` |
| GCP | Pub/Sub, GCS, BigQuery, Vertex AI, Spanner, Cloud Functions | `google.auth.credentials.Credentials` / `GoogleCredentials` |

### Worked Example: Accessing BigQuery via Service Credentials

GCP API enablement checks apply to the project associated with the *calling* identity, not only the resource project. Because the Databricks-generated service account's identity lives in a Databricks-managed project, a subset of "analytics/management plane" GCP APIs — notably BigQuery, Cloud Storage, and Cloud SQL Admin — require you to route the API-enablement and quota check through your own project. "Resource-centric" APIs such as Pub/Sub, Vertex AI, Spanner, and Secret Manager do not need this extra step, which is why Databricks' own examples often use Pub/Sub.

**Routing BigQuery calls through your own project** (classic compute, DBR 16.4 LTS, `SINGLE_USER` access mode):

```python
from google.cloud import bigquery

PROJECT = "my-gcp-project"
credentials = dbutils.credentials.getServiceCredentialsProvider("my-bq-cred")

# Patch with_quota_project — GCPCustomCredentials does not accept the
# refresh_token keyword some client libraries pass to it.
type(credentials).with_quota_project = lambda self, qp: setattr(self, '_quota_project_id', qp) or self

# Set quota_project_id so API calls route through your own project
client = bigquery.Client(
    project=PROJECT,
    credentials=credentials,
    client_options={"quota_project_id": PROJECT},
    location="us-central1",
)

df = client.query("SELECT * FROM `my-project.my_dataset.my_table`").to_dataframe()
```

Grant the generated service account these IAM roles for this pattern:
- `roles/bigquery.dataEditor` (read/write tables)
- `roles/bigquery.jobUser` (run queries)
- `roles/serviceusage.serviceUsageConsumer` (route API calls through your project)

**On serverless compute**, `getServiceCredentialsProvider()` currently implements AWS and Azure credential providers. For GCP access on serverless, use the pre-installed Spark BigQuery connector with a service account key stored in Databricks Secrets:

```python
import base64

sa_key = dbutils.secrets.get("my-scope", "bq-sa-key")
BQ_CREDS = base64.b64encode(sa_key.encode()).decode()

df = spark.read.format("bigquery") \
    .option("credentials", BQ_CREDS) \
    .option("parentProject", "my-gcp-project") \
    .option("project", "my-gcp-project") \
    .load("my_dataset.my_table")
```

This path supports reads well; for writes to BigQuery, use classic compute with a service credential, or Lakehouse Federation. Required IAM roles for the connector: `roles/bigquery.jobUser`, `roles/bigquery.dataViewer`, and `roles/bigquery.readSessionUser` (the Storage Read API used by the Spark connector).

**Choosing an approach:**

| Approach | Auth | UC Governed | Compute | Read | Write |
|---|---|---|---|---|---|
| **Lakehouse Federation** | Service credential in a UC connection | Yes | SQL Warehouse, Serverless, Classic | Yes (SQL) | No |
| **Service Credential + Python SDK** | UC-managed GCP service account | Yes | Classic (DBR 16.2+) | Yes | Yes |
| **Spark BigQuery Connector + SA Key** | Base64 SA key from Secrets | No | Classic, Serverless | Yes | Classic only |

- SQL from a warehouse or serverless? Use **Lakehouse Federation**.
- Spark DataFrame reads on serverless? Use the **Spark BigQuery connector + SA key**.
- Per-user governed read/write? Use a **Service Credential** on classic compute.
- Multiple GCP services in one workflow? A **Service Credential** generalizes beyond BigQuery alone.

### Gotchas — Service Credentials

| Issue | Detail |
|---|---|
| **Storage vs. service** | Service credentials are for services, not for UC managed/external storage locations — use a storage credential for that |
| **No `CREATE` via SQL** | Create through Catalog Explorer, the REST API, or Terraform; SQL manages grants and lifecycle after creation |
| **Runtime matters** | Code usage requires DBR 16.2+; DBR 16.1 and below support Python only (no Scala). SQL warehouses only support service credentials inside batch UC Python UDFs |
| **Default credential is classic-only** | `DATABRICKS_DEFAULT_SERVICE_CREDENTIAL_NAME` applies to classic compute; pass the credential explicitly via `getServiceCredentialsProvider()` on serverless compute or SQL warehouses |
| **GCP access on serverless** | Use the Spark BigQuery connector with a Secrets-based SA key (see pattern above) rather than `getServiceCredentialsProvider()`, which currently targets AWS and Azure |
| **AWS self-assumption is enforced** | Since September 2024, new service credentials require a self-assuming IAM role; existing non-self-assuming roles were migrated starting January 2025 |
| **Azure: managed identity over service principal** | Managed identities avoid secret rotation and can reach network-restricted services; a service principal creating the credential needs the account admin role |
| **GCP: the service account is generated for you** | You don't bring your own SA on GCP — use the generated email to grant IAM roles in the GCP console |
| **GCP quota project routing** | For BigQuery, GCS, and Cloud SQL Admin, set `client_options={"quota_project_id": ...}` and grant `roles/serviceusage.serviceUsageConsumer` on your project, or you will see `403: API has not been used in project ...` |
| **`with_quota_project()` needs a patch** | `GCPCustomCredentials` does not accept the `refresh_token` keyword some libraries pass — apply the one-line patch shown in the worked example above |
| **Manual token refresh** | If calling `credentials.refresh()` directly (for REST usage without the SDK), set `credentials._scopes` first, or the UC temporary-credentials API returns `missing gcp_options` |
| **UC-enabled cluster required** | Clusters must use `SINGLE_USER` or `SHARED` access mode; legacy access modes fail with a Unity Catalog access error |
| **`enableServiceCredentials` Spark conf** | Some workspaces need `spark.databricks.unityCatalog.enableServiceCredentials=true` set at the cluster level |
| **Different accessor inside UDFs** | Use `databricks.service_credentials.getServiceCredentialsProvider()`, not `dbutils.credentials.getServiceCredentialsProvider()` |
| **Deprecated INFORMATION_SCHEMA views** | Use `INFORMATION_SCHEMA.CREDENTIALS` and `INFORMATION_SCHEMA.CREDENTIAL_PRIVILEGES` rather than the older `STORAGE_CREDENTIALS` / `STORAGE_CREDENTIAL_PRIVILEGES` views |
| **GCP Scala dependency note** | Google Cloud SDK Maven dependencies need a shaded Guava version to avoid conflicts |
| **`google-cloud-bigquery` on serverless** | The BigQuery Python client conflicts with pre-installed dependency versions (grpcio/protobuf) on serverless; use the pre-installed Spark BigQuery connector there instead |

---

## Related

- [AI Gateway Patterns](ai-gateway-patterns.md): the four traffic patterns, including outbound external access (Pattern 3), which uses UC Connections
- [Identity](../identity/): the identity model determines which user or service principal is checked for `USE CONNECTION` / `ACCESS`
- [Data Governance](../data-governance/): row filters and column masks govern data; connections and service credentials govern tools and services
- [Observability](../observability/): `USE CONNECTION` and service-credential access checks are audited in system tables

## References

- [Connect to external HTTP services](https://docs.databricks.com/aws/en/query-federation/http)
- [Service credentials: governed access to cloud services](https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-services/service-credentials)
- [Model serving region availability](https://learn.microsoft.com/en-us/azure/databricks/resources/feature-region-support#azure-model-serving)
- [Migrate to serverless routing for HTTP connections](https://learn.microsoft.com/en-us/azure/databricks/query-federation/http-migration)
- [Configure private connectivity to resources in your VNet](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/pl-to-internal-network)
- [Unity Catalog privileges](https://docs.databricks.com/en/data-governance/unity-catalog/manage-privileges/privileges.html)
- [Terraform `databricks_credential` resource](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/credential)
