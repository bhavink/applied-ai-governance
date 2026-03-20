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

## Key Concepts

### Role-Based Service Principals

Instead of one SP per external user (doesn't scale), map roles to SPs:

| External Role | Databricks SP | UC Group | Data Access |
|---------------|---------------|----------|-------------|
| Sales (West region) | `sp-role-west-sales` | `west_sales` | West region rows only |
| Sales (East region) | `sp-role-east-sales` | `east_sales` | East region rows only |
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

## Databricks Documentation

- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) (token exchange mechanics)
- [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication) (SP patterns for AI apps)
- [Unity Catalog access control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) (grants, row filters)
