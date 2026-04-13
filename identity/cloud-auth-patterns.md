# Cloud-Specific Authentication Patterns

> **TL;DR**: Three IdP patterns for token federation to Databricks, each with distinct governance implications. Entra ID uses built-in tenant OIDC endpoints (no custom auth servers). Okta requires a custom Authorization Server. Azure Managed Identity enables secretless authentication from Azure compute. All exchange IdP tokens for Databricks tokens via RFC 8693.

---

## Why Cloud Auth Matters for Governance

The authentication path determines:

- **What identity UC sees** — human email (U2M) or SP UUID (M2M)
- **Whether row filters fire per-user** — only with OBO/U2M tokens
- **Audit trail fidelity** — federation logs show the IdP identity + the Databricks SP, not just one
- **Credential exposure risk** — Managed Identity eliminates client_secret entirely

---

## Pattern Comparison

| Pattern | IdP | Identity in UC | Credentials stored | Best for |
|---|---|---|---|---|
| **Entra U2M** | Azure AD | Human email (via federation) | Client secret in app registration | Internal Azure apps with per-user governance |
| **Entra M2M** | Azure AD | SP UUID | Client secret | Background jobs, pipelines on Azure |
| **Azure Managed Identity** | Azure IMDS | SP UUID | **None** — Azure manages the credential | Azure VMs, AKS, Functions calling Databricks |
| **Okta U2M** | Okta | Human email (via federation) | None (PKCE) or client secret | Multi-cloud apps with Okta as IdP |
| **Okta M2M** | Okta | SP UUID | Client secret in Okta | Background jobs with Okta-managed credentials |
| **Native AAD token** | Azure AD | Depends on token type | Azure credential | Azure-only shortcut; has ML API limitations |

---

## Key Governance Differences: Entra vs Okta

| Aspect | Entra ID | Okta |
|---|---|---|
| Custom Authorization Server | Not available — uses built-in tenant OIDC | **Required** — must create one with custom audience and scopes |
| Audience in federation policy | `api://<app-id>` (app registration ID) | Custom (e.g., `api://databricks`) |
| Subject claim for U2M | `upn` (user principal name) | `sub` or `email` (configurable) |
| M2M subject | Databricks SP UUID in `client_id` param | Databricks SP UUID in `client_id` param |
| Secretless option | Azure Managed Identity (IMDS token exchange) | Not available |

---

## Federation Policy Governance

Every federation trust requires a policy configured at the Databricks account level specifying:

1. **Issuer URL** — which IdP is trusted
2. **Audience** — which app registration/auth server the token was issued for
3. **Subject claim** — which JWT claim identifies the user or SP

The federation policy is the **trust boundary**. A misconfigured policy (wrong audience, wrong subject claim) either blocks legitimate access or — worse — maps the wrong identity to a Databricks SP.

### Common misconfigurations

| Error | Cause | Governance risk |
|---|---|---|
| `400 invalid_grant` on exchange | Audience in JWT ≠ federation policy audience | Access blocked (noisy failure) |
| Subject claim mismatch | Policy expects `upn` but token has `email` | Wrong user mapped to SP (silent failure) |
| M2M `client_id` confusion | Used IdP client ID instead of Databricks SP UUID | Wrong SP gets the token (identity confusion) |
| Native AAD token 401 on ML APIs | Model Serving doesn't accept AAD tokens directly | Forces fallback to federation (correct, but unexpected) |

---

## Related

- [Authentication](authentication.md) — IdP delegation overview
- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [Federation Exchange](federation.md) — Conceptual model and enforcement points

For MSAL code examples, PKCE flow implementation, Okta custom auth server setup, and Azure MI token exchange scripts, see the [fieldkit cloud auth guides](https://github.com/bhavink/fieldkit).
