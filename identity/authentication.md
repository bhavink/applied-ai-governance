# Authentication (AuthN)

> AuthN is delegated to Identity Providers. Databricks does not run its own IdP.

## How It Works

Every Databricks workspace authenticates users through an external Identity Provider. The cloud determines the default, but the mechanics are the same: the IdP verifies the user, issues a token, and Databricks trusts that token.

| Cloud | IdP | Customizable? |
|-------|-----|---------------|
| Azure | Entra ID (Azure AD) | **No.** Built-in, out of the box. Entra IS the IdP. SSO, MFA, Conditional Access all inherited from your tenant. |
| GCP | Cloud Identity / Google Workspace | **Partially.** Cloud Identity is the default, but you can configure SSO with your own SAML/OIDC provider on top. |
| AWS | Bring Your Own | **Yes.** No built-in IdP. You configure any SAML 2.0 or OIDC provider (Okta, Entra, Ping, OneLogin) via account-level SSO. |

The important point: **you don't configure authentication inside Databricks.** The IdP handles user verification, password management, MFA, and conditional access. Databricks trusts the IdP's assertion. Users never create "Databricks passwords."

## Unified Client Authentication

For programmatic access (SDKs, CLI, REST APIs, Terraform), Databricks supports a unified authentication model that works identically across all clouds:

| Method | Use Case |
|--------|----------|
| **OAuth U2M** | Interactive tools (CLI, IDE plugins, notebooks). User authenticates via browser, gets a scoped token. |
| **OAuth M2M** | Automated workloads (CI/CD, jobs, apps). Service principal authenticates with client credentials. |
| **PAT** | Legacy/dev-only. Static token tied to a user. Avoid in production. |
| **Databricks-managed profiles** | `~/.databrickscfg` profiles abstract auth method from code. SDK auto-resolves. |

The unified auth model means your code doesn't care which cloud it runs on. `WorkspaceClient()` with no arguments picks up credentials from environment variables or config profiles automatically.

## Databricks Documentation

AuthN is well-documented. Start here:

- [Unified client authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth) (the auth model)
- [OAuth U2M authentication](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) (interactive)
- [OAuth M2M authentication](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m) (automated)
- [Single sign-on (SSO)](https://docs.databricks.com/aws/en/security/auth/single-sign-on/) (workspace IdP config)

These patterns are cloud-agnostic in principle, with minor endpoint differences per cloud.

## What AuthN Does NOT Cover

AuthN answers "who are you?" It does not answer:

- What data can you see? (UC grants, row filters, column masks)
- What APIs can you call? (OAuth scopes)
- What external services can you reach? (UC connections)
- What shows up in the audit trail? (depends on token type: OBO vs M2M)

Those are all **authorization** decisions. See [Authorization](authorization.md).
