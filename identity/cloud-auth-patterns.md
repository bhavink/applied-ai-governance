# Cloud-Specific Authentication Patterns — Entra ID and Okta

> **TL;DR**: Cloud-specific token federation patterns. Entra ID uses built-in tenant OIDC endpoints — no custom auth servers exist. Okta requires a custom Authorization Server with explicit audience, scopes, and access policy configuration. Both exchange their IdP-issued tokens for Databricks tokens via RFC 8693 (`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`). The exchange endpoint is always `{workspace}/oidc/v1/token`.

---

## Entra ID (Azure)

### Two Approaches on Azure

| Approach | How | Best For |
|---|---|---|
| **Token Federation** (recommended) | Entra token → RFC 8693 exchange → Databricks token | All APIs, cloud-portable pattern |
| **Native AAD token** | Entra token used directly as Bearer | Azure Databricks only; has ML API limitations |

---

### App Registration Setup

**Azure Portal → App registrations → New registration:**

1. **Name**: your app (e.g. `my-databricks-app`)
2. **Platform**: Web (recommended for server-side apps)
3. **Redirect URI**: `http://localhost:8080/callback` (local dev) or your app URL

**For U2M (user login):**
- Expose an API: **API → Expose an API → Add scope**
  - Scope name: `databricks-access` (or any name)
  - This creates an audience: `api://<app-id>`
- In federation policy: audience = `api://<app-id>`, subject claim = `upn`

**For M2M (service principal):**
- Add client secret: **Certificates & secrets → New client secret**
- In federation policy: audience = `api://<app-id>`, subject = Databricks SP UUID

> **Note**: Unlike Okta, Entra does NOT have custom authorization servers. U2M and M2M both use the same built-in tenant OIDC endpoints.

---

### U2M — User Login with MSAL

```python
import msal
import secrets
import requests

# Config
TENANT_ID = "<entra-tenant-id>"
CLIENT_ID = "<entra-app-client-id>"
CLIENT_SECRET = "<entra-app-client-secret>"    # for confidential client
REDIRECT_URI = "http://localhost:8080/callback"
SCOPES = ["api://<app-id>/databricks-access"]  # scope you exposed on the app
WORKSPACE_HOST = "https://adb-1234567890.7.azuredatabricks.net"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"


def get_msal_app():
    return msal.ConfidentialClientApplication(
        client_id=CLIENT_ID,
        client_credential=CLIENT_SECRET,
        authority=AUTHORITY,
    )


# Step 1: Generate authorization URL → redirect user
def get_auth_url() -> tuple[str, str]:
    state = secrets.token_urlsafe(32)
    msal_app = get_msal_app()
    auth_url = msal_app.get_authorization_request_url(
        scopes=SCOPES,
        state=state,
        redirect_uri=REDIRECT_URI,
    )
    return auth_url, state


# Step 2: Handle callback → exchange code for Entra token
def exchange_code_for_token(authorization_code: str) -> str:
    msal_app = get_msal_app()
    result = msal_app.acquire_token_by_authorization_code(
        code=authorization_code,
        scopes=SCOPES,
        redirect_uri=REDIRECT_URI,
    )
    if "error" in result:
        raise ValueError(f"MSAL error: {result['error_description']}")
    return result["access_token"]   # Entra access token


# Step 3: Exchange Entra token for Databricks token (RFC 8693)
def exchange_for_databricks_token(entra_token: str) -> str:
    resp = requests.post(
        f"{WORKSPACE_HOST}/oidc/v1/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": entra_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": "all-apis",
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# Full U2M flow (e.g. in a Flask/FastAPI callback handler):
def handle_oauth_callback(authorization_code: str):
    entra_token = exchange_code_for_token(authorization_code)
    databricks_token = exchange_for_databricks_token(entra_token)

    from databricks.sdk import WorkspaceClient
    w = WorkspaceClient(host=WORKSPACE_HOST, token=databricks_token)
    # w now operates as the logged-in user
    # UC row filters and column masks fire as that user
    return w
```

---

### M2M — Service Principal with MSAL

```python
import msal
import requests

TENANT_ID = "<entra-tenant-id>"
CLIENT_ID = "<sp-entra-app-client-id>"
CLIENT_SECRET = "<sp-entra-app-client-secret>"
SCOPES = ["api://<app-id>/.default"]           # .default for M2M client credentials
WORKSPACE_HOST = "https://adb-1234567890.7.azuredatabricks.net"
DATABRICKS_SP_UUID = "<databricks-sp-uuid>"    # from Databricks Account Console
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"


def get_databricks_token_m2m() -> str:
    """Non-interactive M2M: Entra client credentials → Databricks token."""

    # Step 1: Get Entra token via client credentials (no user involved)
    sp_app = msal.ConfidentialClientApplication(
        client_id=CLIENT_ID,
        client_credential=CLIENT_SECRET,
        authority=AUTHORITY,
    )
    result = sp_app.acquire_token_for_client(scopes=SCOPES)
    if "error" in result:
        raise ValueError(f"MSAL error: {result['error_description']}")
    entra_token = result["access_token"]

    # Step 2: Exchange for Databricks token
    resp = requests.post(
        f"{WORKSPACE_HOST}/oidc/v1/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": entra_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": "all-apis",
            "client_id": DATABRICKS_SP_UUID,   # links Entra SP → Databricks SP
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# Usage
token = get_databricks_token_m2m()
from databricks.sdk import WorkspaceClient
w = WorkspaceClient(host=WORKSPACE_HOST, token=token)
# Operates as the service principal
```

---

### Native AAD Token (Azure-Only Shortcut)

Azure Databricks also accepts Entra tokens directly — no federation exchange needed. Simpler but has limitations.

```python
from azure.identity import DefaultAzureCredential, InteractiveBrowserCredential
import requests

# M2M (from Azure VM, AKS, or with env vars set)
credential = DefaultAzureCredential()
token = credential.get_token("2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default")

# U2M (interactive browser)
credential = InteractiveBrowserCredential(client_id="<app-client-id>")
token = credential.get_token("2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default")

headers = {"Authorization": f"Bearer {token.token}"}
resp = requests.get(f"{WORKSPACE_HOST}/api/2.0/clusters/list", headers=headers)
```

**Limitations:**
- Azure Databricks only (not portable to AWS/GCP)
- Some Model Serving / ML APIs do not accept AAD tokens directly
- Recommendation: use token federation (RFC 8693) for any production use

---

### Federation Policy for Entra

Account Console → Settings → Security → Authentication → Federation Policies:

**For U2M:**
```
Issuer URL:    https://login.microsoftonline.com/<tenant-id>/v2.0
Audience:      api://<app-id>
Subject claim: upn              (matches user's UPN in Databricks)
```

**For M2M (workload identity):**
```
Audience:      api://<app-id>/.default
Subject:       <databricks-sp-uuid>
Subject claim: oid              (Entra object ID of the SP)
```

---

### Entra-Specific Gotchas

| Issue | Cause | Fix |
|---|---|---|
| `AADSTS500011`: resource not found | Scope doesn't match any registered app | Ensure scope is `api://<app-id>/scope-name`, not Databricks resource ID |
| `400 invalid_grant` on Databricks exchange | Audience in JWT does not match federation policy audience | Inspect JWT at jwt.io; match `aud` claim to policy audience exactly |
| Subject claim mismatch | Policy uses `upn` but user's token has different UPN format | Check actual claim in JWT; sometimes it's `preferred_username` |
| M2M: `client_id` rejected | Used Entra client ID instead of Databricks SP UUID | `client_id` in the Databricks exchange = SP UUID from Databricks console |
| Native AAD token 401 on Model Serving | Model Serving doesn't accept AAD tokens directly | Use token federation (RFC 8693 exchange) instead |
| Entra has no custom auth server | Trying to create Okta-style custom authorization server | Entra doesn't support this — use built-in tenant OIDC endpoints |

---

## Azure Managed Identity (No client_secret)

### When to Use

- External Azure workload (VM, AKS pod, Azure Function) calls Databricks without storing a client_secret
- Azure Managed Identity is already set up for the calling workload
- Credentials managed by Azure rather than Databricks secrets

### Flow

```
Azure workload (VM / AKS / Function)
  → gets Azure MI JWT from IMDS
    → exchanges for Databricks OAuth token (RFC 8693)
      → calls Databricks API
```

### Step 1 — Get Azure MI Token

```bash
# On the Azure VM / inside AKS pod
AZURE_MI_TOKEN=$(curl -s \
  "http://169.254.169.254/metadata/instance/compute/identity/access_token?resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" \
  -H "Metadata: true" | jq -r .access_token)
```

> `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d` is the Databricks Azure app ID (resource ID).

### Step 2 — Exchange for Databricks Token

```bash
DATABRICKS_TOKEN=$(curl --request POST \
  "https://<workspace-hostname>/oidc/v1/token" \
  --data "subject_token=${AZURE_MI_TOKEN}" \
  --data "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data "scope=all-apis" \
  | jq -r .access_token)
```

### Python Equivalent

```python
import requests

def get_databricks_token_via_mi(workspace_host: str) -> str:
    """Exchange Azure MI token for Databricks OAuth token."""
    # Get Azure MI token
    mi_resp = requests.get(
        "http://169.254.169.254/metadata/instance/compute/identity/access_token",
        params={"resource": "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"},
        headers={"Metadata": "true"},
        timeout=10,
    )
    mi_resp.raise_for_status()
    azure_token = mi_resp.json()["access_token"]

    # Exchange for Databricks token
    db_resp = requests.post(
        f"{workspace_host}/oidc/v1/token",
        data={
            "subject_token": azure_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "scope": "all-apis",
        },
        timeout=15,
    )
    db_resp.raise_for_status()
    return db_resp.json()["access_token"]
```

### Federation Policy Prerequisite

Token exchange requires a federation trust policy configured on your Databricks account. The policy specifies which Azure tenants and MI object IDs are trusted. Configure at Account Console → Settings → Security → Authentication → Federation Policies.

### Managed Identity Gotchas

| Issue | Detail |
|---|---|
| Federation policy required | Must be configured at account level before token exchange works |
| Azure-only | RFC 8693 exchange with Azure MI only works on Azure Databricks workspaces |
| IMDS only from Azure compute | The `169.254.169.254` IMDS endpoint is only available inside Azure VMs, AKS pods, or Functions |

---

## Okta

### Key Difference: Custom Authorization Server Required

Unlike Entra (which uses built-in OIDC endpoints), Okta **requires a custom Authorization Server** to:
- Define a custom audience (what Databricks will validate as the `aud` claim)
- Create custom scopes (e.g. `databricks-token-federation`)
- Set access policies controlling who gets tokens

### Setup

#### 1. Create Authorization Server

Okta Admin Console → Security → API → Authorization Servers → Add Authorization Server:

```
Name:      Databricks
Audience:  api://databricks    ← becomes the `aud` claim in the JWT
```

#### 2. Add Scopes

Scopes tab → Add Scope:
- For U2M: `databricks-access` (or any name)
- For M2M: `databricks-token-federation`

#### 3. Add Access Policy and Rule

Access Policies tab → Add Policy → Add Rule:
- Grant types: Authorization Code (U2M) or Client Credentials (M2M)
- Scopes: the scopes created above

#### 4. Create Okta Application

Applications → Create App Integration:
- **U2M**: OIDC → Web Application → Authorization Code + PKCE
- **M2M**: API Services (client credentials)
- Set **Login redirect URI** to your callback URL

---

### U2M — User Login with PKCE

```python
import hashlib, base64, secrets, urllib.parse, requests

OKTA_DOMAIN = "https://your-org.okta.com"
AUTH_SERVER_ID = "<your-auth-server-id>"       # from Okta Auth Server URL
CLIENT_ID = "<okta-app-client-id>"
REDIRECT_URI = "http://localhost:8080/callback"
SCOPES = "openid profile databricks-access"
WORKSPACE_HOST = "https://your-workspace.cloud.databricks.com"

AUTHORIZE_ENDPOINT = f"{OKTA_DOMAIN}/oauth2/{AUTH_SERVER_ID}/v1/authorize"
TOKEN_ENDPOINT = f"{OKTA_DOMAIN}/oauth2/{AUTH_SERVER_ID}/v1/token"


def generate_pkce():
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


# Step 1: Build authorization URL
def get_auth_url():
    verifier, challenge = generate_pkce()
    state = secrets.token_urlsafe(16)
    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    return f"{AUTHORIZE_ENDPOINT}?{urllib.parse.urlencode(params)}", state, verifier


# Step 2: Exchange code for Okta access token
def exchange_code_for_okta_token(code: str, verifier: str) -> str:
    resp = requests.post(
        TOKEN_ENDPOINT,
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
            "client_id": CLIENT_ID,
            "code_verifier": verifier,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# Step 3: Exchange Okta token for Databricks token
def exchange_for_databricks_token(okta_token: str) -> str:
    resp = requests.post(
        f"{WORKSPACE_HOST}/oidc/v1/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": okta_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": "all-apis",
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# Full flow
auth_url, state, verifier = get_auth_url()
# → redirect user to auth_url
# → they log in to Okta
# → Okta redirects to /callback?code=...&state=...
# In the callback:
okta_token = exchange_code_for_okta_token(authorization_code, verifier)
databricks_token = exchange_for_databricks_token(okta_token)

from databricks.sdk import WorkspaceClient
w = WorkspaceClient(host=WORKSPACE_HOST, token=databricks_token)
# Operates as the logged-in user
```

---

### M2M — Service Principal Client Credentials

```python
import requests

OKTA_DOMAIN = "https://your-org.okta.com"
AUTH_SERVER_ID = "<your-auth-server-id>"
CLIENT_ID = "<okta-m2m-app-client-id>"
CLIENT_SECRET = "<okta-m2m-app-client-secret>"
SCOPES = "databricks-token-federation"
WORKSPACE_HOST = "https://your-workspace.cloud.databricks.com"
DATABRICKS_SP_UUID = "<databricks-sp-uuid>"    # SP UUID from Databricks Account Console

TOKEN_ENDPOINT = f"{OKTA_DOMAIN}/oauth2/{AUTH_SERVER_ID}/v1/token"


def get_databricks_token_m2m() -> str:
    # Step 1: Get Okta token via client credentials
    okta_resp = requests.post(
        TOKEN_ENDPOINT,
        data={
            "grant_type": "client_credentials",
            "scope": SCOPES,
        },
        auth=(CLIENT_ID, CLIENT_SECRET),    # HTTP Basic Auth for Okta M2M
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    okta_resp.raise_for_status()
    okta_token = okta_resp.json()["access_token"]

    # Step 2: Exchange for Databricks token
    db_resp = requests.post(
        f"{WORKSPACE_HOST}/oidc/v1/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": okta_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "scope": "all-apis",
            "client_id": DATABRICKS_SP_UUID,    # Databricks SP UUID — not Okta client ID
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    db_resp.raise_for_status()
    return db_resp.json()["access_token"]
```

---

### Federation Policy for Okta

Account Console → Settings → Security → Authentication → Federation Policies:

**For U2M (user tokens):**
```
Issuer URL:    https://your-org.okta.com/oauth2/<auth-server-id>
Audience:      api://databricks          ← must match Auth Server audience
Subject claim: sub                       (or "email" if mapped in Okta profile)
```

**For M2M (workload identity):**
```
Audience:      api://databricks
Subject:       <databricks-sp-uuid>
Subject claim: sub                       (Okta client ID is typically the sub claim)
```

> **Critical**: The `aud` claim in the Okta JWT must exactly match the Databricks federation policy audience. Inspect the token at [jwt.io](https://jwt.io) to verify.

---

### Okta vs Entra — Quick Comparison

| Feature | Okta | Entra ID |
|---|---|---|
| Custom Authorization Server | Required | Not available |
| Audience configuration | Custom (you define it) | Built-in (app ID format) |
| M2M token endpoint | Custom auth server `/token` | Tenant `/token` with `.default` scope |
| Subject claim for users | `sub` (or custom) | `upn` (usually) |
| PKCE support | Yes | Yes |
| DPoP support | Yes | Limited |
| Client auth method | Client secret or private key JWT | Client secret or certificate |

---

### Okta-Specific Gotchas

| Issue | Cause | Fix |
|---|---|---|
| `400 invalid_grant` on Databricks exchange | Audience mismatch | Okta Auth Server audience must match federation policy audience exactly |
| `401` from Okta token endpoint | Wrong scopes or policy not granting | Check Access Policy rules in Okta; ensure scope is allowed for the grant type |
| PKCE verifier mismatch | `code_verifier` not stored in session | Store verifier when generating challenge; retrieve on callback |
| Redirect URI mismatch | Okta app redirect URIs must be exact | Copy exact URL including trailing slash from Okta app config |
| M2M `client_id` in exchange | Passing Okta client ID instead of Databricks SP UUID | `client_id` in `/oidc/v1/token` exchange = Databricks SP UUID |
| Okta `403` on custom scope | Scope not in Access Policy | Add scope to the policy rule's allowed scopes list |
| `sub` claim is Okta user ID not email | Default Okta subject claim is opaque ID | Configure subject claim in Auth Server to use `email`; update federation policy |

---

## Related

- [`federation.md`](federation.md) — IdP-agnostic federation patterns
- [`authentication.md`](authentication.md) — Databricks auth overview and pattern decision tree
- [`gcp-workload-identity-federation.md`](gcp-workload-identity-federation.md) — GCP equivalent (Workload Identity Federation)
- [`u2m-external-obo.md`](u2m-external-obo.md) — U2M OBO from external apps (Cloudflare Pages pattern)
