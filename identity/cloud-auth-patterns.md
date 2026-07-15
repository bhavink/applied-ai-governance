<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/_azure/entra-oauth.md, auth/_okta/token-federation.md, auth/gcp-wif-databricks.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation
    - https://learn.microsoft.com/en-us/azure/databricks/dev-tools/auth/
  This file is auto-prepared and human-reviewed before publish.
-->

# Cloud-Specific Authentication Patterns

> **TL;DR**: Databricks federates external identities from Entra ID (Azure), Okta (any cloud), and Google Cloud (Workload Identity Federation) by exchanging an IdP-issued token for a Databricks token via RFC 8693 token exchange. The identity provider setup differs by IdP and cloud, but the exchange call into Databricks — `POST /oidc/v1/token` — is the same shape everywhere.

---

## Why Cloud Auth Matters for Governance

The authentication path determines:

- **What identity Unity Catalog sees** — human email (U2M) or service-principal UUID (M2M)
- **Whether row filters fire per-user** — only with on-behalf-of / U2M tokens
- **Audit trail fidelity** — federation logs show the IdP identity and the Databricks service principal
- **Credential exposure risk** — workload-identity patterns (Azure Managed Identity, GCP Workload Identity Federation) avoid storing a client secret at all

---

## Pattern Comparison

| Pattern | IdP / Provider | Identity in UC | Credentials stored | Best for |
|---|---|---|---|---|
| **Entra U2M** | Azure AD (Entra ID) | Human email (via federation) | Client secret in app registration | Azure apps with per-user governance |
| **Entra M2M** | Azure AD (Entra ID) | SP UUID | Client secret | Background jobs, pipelines on Azure |
| **Native AAD token** | Azure AD (Entra ID) | Depends on token type | Azure credential | Azure-only shortcut for workspace APIs; use token federation for Model Serving and other ML APIs |
| **Azure Managed Identity** | Azure IMDS | SP UUID | None — Azure manages the credential | Azure VMs, AKS, Functions calling Databricks |
| **Okta U2M** | Okta | Human email (via federation) | None (PKCE) or client secret | Multi-cloud apps with Okta as IdP |
| **Okta M2M** | Okta | SP UUID | Client secret in Okta | Background jobs with Okta-managed credentials |
| **GCP Workload Identity Federation** | Google Cloud (GSA) | SP UUID | None — Google issues the ID token | GKE, Cloud Run, Compute Engine, Cloud Functions, Composer, or a developer workstation calling Databricks |

---

## Azure: Entra ID OAuth

Custom applications authenticate users (U2M) or service principals (M2M) through Entra ID, then exchange the Entra token for a Databricks OAuth token using the same RFC 8693 token-exchange call. Entra uses its built-in tenant OIDC endpoints for both flows — there is no separate authorization-server object to create, which is the main configuration difference from Okta (below).

### Federation policy fields

| Flow | Issuer URL | Audience | Subject claim |
|---|---|---|---|
| U2M | `https://login.microsoftonline.com/<tenant-id>/v2.0` | `api://<app-id>` (the scope exposed on the app registration) | `upn` (matches the user's UPN in Databricks) |
| M2M | `https://login.microsoftonline.com/<tenant-id>/v2.0` | `api://<app-id>/.default` | `oid` (the Entra object ID of the service principal) — the Databricks SP UUID is passed separately as `client_id` in the exchange |

### Native AAD token shortcut

Azure Databricks also accepts an Entra-issued token directly as a bearer token, without a token-exchange call — useful for quick scripts against workspace REST APIs. This shortcut is Azure-specific (not portable to AWS or GCP), and Model Serving and other ML APIs expect a Databricks-issued token, so token federation is the pattern to use once an app moves past a proof of concept.

### Configuration checks

| Symptom | Likely cause | What to check |
|---|---|---|
| `AADSTS500011` resource not found | Scope doesn't match a registered app | Scope must be `api://<app-id>/scope-name`, not a Databricks resource ID |
| `400 invalid_grant` on the Databricks exchange | Audience in the JWT doesn't match the federation policy audience | Inspect the JWT and confirm the `aud` claim matches the policy exactly |
| Subject claim mismatch | Policy expects `upn` but the token carries a different claim | Confirm the actual claim name in the token — some tenants populate `preferred_username` instead |
| M2M `client_id` rejected | Entra client ID passed instead of the Databricks SP UUID | The `client_id` in the Databricks exchange call is the SP UUID from the account console, not the Entra app ID |
| Native AAD token rejected by Model Serving | Model Serving expects a Databricks-issued OAuth token | Use the RFC 8693 token-exchange flow for ML APIs |

---

## Okta Token Federation

Okta federates to Databricks the same way — exchange an Okta-issued token for a Databricks token at `/oidc/v1/token` — but Okta requires a **custom Authorization Server** to define the audience, scopes, and access policy that Databricks validates against. U2M flows support PKCE; M2M flows use client-credentials grants, and Okta additionally supports DPoP for proof-of-possession tokens.

### Federation policy fields

| Flow | Issuer URL | Audience | Subject claim |
|---|---|---|---|
| U2M | `https://<org>.okta.com/oauth2/<auth-server-id>` | `api://databricks` (or whatever audience the Authorization Server declares) | `sub`, or `email` if the Authorization Server is configured to emit it |
| M2M | `https://<org>.okta.com/oauth2/<auth-server-id>` | Same custom audience | `sub` — the Databricks SP UUID is passed separately as `client_id` in the exchange |

### Entra vs Okta at a glance

| Aspect | Entra ID | Okta |
|---|---|---|
| Authorization server | Built-in tenant OIDC endpoints | Custom Authorization Server, created per integration |
| Audience configuration | App-registration ID format (`api://<app-id>`) | Custom audience defined on the Authorization Server |
| Subject claim for U2M | `upn` (typically) | `sub` or `email`, configurable |
| M2M subject | Databricks SP UUID passed as `client_id` | Databricks SP UUID passed as `client_id` |
| Proof-of-possession (DPoP) | Limited support | Supported |
| Secretless workload identity | Azure Managed Identity | Not applicable — pair with GCP or Azure workload identity where secretless auth is required |

### Configuration checks

| Symptom | Likely cause | What to check |
|---|---|---|
| `400 invalid_grant` on the Databricks exchange | Audience mismatch | Authorization Server audience must match the federation policy audience exactly |
| `401` from the Okta token endpoint | Scope not granted by policy | Confirm the Access Policy rule allows the requested scope for that grant type |
| PKCE verifier mismatch | `code_verifier` not preserved across the redirect | Store the verifier in session state when generating the challenge, retrieve it in the callback |
| Redirect URI mismatch | Okta app redirect URIs must match exactly | Compare the exact URL, including trailing slash, against the Okta app configuration |
| `403` on a custom scope | Scope not included in the Access Policy | Add the scope to the policy rule's allowed-scopes list |
| Subject claim is an opaque Okta ID | Default Okta subject claim is not human-readable | Configure the Authorization Server to emit `email` and update the federation policy's subject claim accordingly |

---

## GCP: Workload Identity Federation

Any GCP workload that runs as a Google Service Account (GSA) — GKE, Cloud Run, Compute Engine, Cloud Functions, Composer, or a developer workstation — can authenticate to Databricks APIs without storing a Databricks secret. The workload requests a Google ID token scoped to the Databricks workspace URL, then exchanges it for a Databricks token via the same RFC 8693 flow used by Entra and Okta.

```
Any GCP Workload (with GSA identity)
  → Google ID Token (aud: Databricks workspace URL)
  → POST /oidc/v1/token (RFC 8693 exchange + client_id)
  → Databricks OAuth Token (SP identity)
  → Any Databricks API (AI Gateway, SQL, Unity Catalog, Jobs, etc.)
```

How the Google ID token is obtained varies by compute environment, but the Databricks-side exchange is identical in every case:

| GCP environment | How the token is obtained | Extra setup |
|---|---|---|
| GKE | Workload Identity injects GSA credentials into the pod | Kubernetes service account bound to the GSA, plus a KSA annotation |
| Cloud Run / Compute Engine / Cloud Functions / Composer | Automatic via the metadata server | Assign the GSA as the resource's service identity |
| GitHub Actions | GCP Workload Identity Federation for GitHub, OIDC token exchange | Configure a GCP WIF pool for GitHub |
| Developer workstation | `gcloud auth print-identity-token --impersonate-service-account=<GSA>` | Grant `roles/iam.serviceAccountTokenCreator` on the GSA |

### Setup

1. **Get the GSA's numeric unique ID** (`gcloud iam service-accounts describe <gsa-email> --format='value(uniqueId)'`) — this is the `sub` claim Databricks matches against, not the GSA email.
2. **Create a Databricks service principal at the account level.** Workspace-local service principals do not support federation policies.
3. **Add a federation policy on the SP** with issuer `https://accounts.google.com`, subject = the GSA numeric ID, audience = the Databricks workspace URL, subject claim = `sub`.
4. **Grant the SP the Databricks permissions the workload needs** (query access on an AI Gateway or Model Serving endpoint, warehouse usage, table grants, job run permissions, etc.).

### The token exchange

```
POST https://<workspace-url>/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<Google ID Token>
&subject_token_type=urn:ietf:params:oauth:token-type:jwt
&scope=all-apis
&client_id=<Databricks SP UUID>
```

### Configuration checks

| Symptom | Likely cause | What to check |
|---|---|---|
| `TOKEN_INVALID` — "ensure a valid federation policy has been configured" | `client_id` omitted from the exchange | The exchange must include `client_id=<SP UUID>`; without it Databricks can't match the federation policy to the SP even when issuer, subject, and audience all line up |
| Federation policy doesn't seem to take effect | Newly created or updated policies take a short time to propagate | Allow a minute or two after creating/updating a policy before retesting |
| Policy subject never matches | Policy configured with the GSA email instead of its numeric unique ID | Google ID tokens carry the GSA's numeric unique ID as `sub`, not the email address |
| Federation policy rejected at creation | Service principal created at the workspace level | Create the SP at the account level; workspace-local SPs don't support federation policies |

Full setup instructions, a five-minute end-to-end validation script, and Java/Python/bash code samples are maintained in [GCP Workload Identity Federation → Databricks](gcp-workload-identity-federation.md).

---

## Federation Policy Governance

Every federation trust requires a policy configured at the Databricks account level specifying:

1. **Issuer URL** — which IdP is trusted
2. **Audience** — which app registration/authorization server/workload the token was issued for
3. **Subject claim** — which JWT claim identifies the user or service principal

The federation policy is the **trust boundary**. A misconfigured policy (wrong audience, wrong subject claim) either blocks legitimate access or — worse — maps the wrong identity to a Databricks service principal.

### Common misconfigurations

| Error | Cause | Governance risk |
|---|---|---|
| `400 invalid_grant` on exchange | Audience in JWT ≠ federation policy audience | Access blocked (noisy failure) |
| Subject claim mismatch | Policy expects `upn`/`sub` but token has a different claim | Wrong user mapped to SP (silent failure) |
| M2M `client_id` confusion | IdP client ID used instead of the Databricks SP UUID | Wrong SP receives the token (identity confusion) |
| GCP subject mismatch | GSA email used instead of the GSA numeric unique ID | Access blocked until the policy is corrected |
| Native AAD token on an ML API | Model Serving expects a Databricks-issued token, not a raw AAD token | Use token federation (RFC 8693) for ML API calls |

---

## Related

- [Authentication](authentication.md) — IdP delegation overview
- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [Federation Exchange](federation.md) — Conceptual model and enforcement points
- [GCP Workload Identity Federation → Databricks](gcp-workload-identity-federation.md) — full GCP setup, validation script, and code samples
- [Databricks: Authenticate access to Databricks resources](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation) — OAuth federation reference
- [Microsoft Learn: Azure Databricks authentication](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/auth/) — Entra ID auth reference
