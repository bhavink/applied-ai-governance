# Identity & Access Control

> **Pillar 2**: Who is making the request, and what can they do?

Two distinct concepts, often conflated:

- **Authentication (AuthN)**: Who are you? Delegated to Identity Providers. Databricks does not manage passwords or user directories.
- **Authorization (AuthZ)**: What can you do? This is where Databricks plays. Unity Catalog is the authorization engine for all AI services.

## Reading Order

1. [Authentication](authentication.md): How AuthN works across clouds (brief, links to official docs)
2. [Authorization](authorization.md): The three token patterns, UC governance, OAuth scopes, service principals
2a. [Production Federation Guide](federation-production.md): **Start here for an external app accessing Databricks.** The decision framework across the three identity paths (per-user exchange, role-based exchange, Apps-proxy OBO), token lifecycle at scale, and cross-cutting hardening. Routes into docs 3, 4, and 5 below.
3. [U2M from External Apps](u2m-external-obo.md): OBO from a non-Databricks app when users are already provisioned in the workspace
4. [Per-User BYO-IdP Federation](byoidp-peruser-federation.md): External app + customer-owned IdP → per-user identity and row-level security via account-wide token exchange (with the no-JWKS fallback)
4a. [Teams / Copilot Studio → Genie Agents & Agent Bricks OBO](teams-copilot-genie-obo.md): Per-user identity into Genie Agents from Microsoft Teams and Copilot Studio — and the second, independent gate (Genie Agent publish mode) that OBO alone doesn't satisfy
4b. [Cross-Tenant Entra + Embedded AI/BI](cross-tenant-entra-embedding.md): Single Microsoft identity, no second login on an embedded dashboard, across two Entra tenants — the account SSO swap, the cross-tenant issuer choice, the B2B guest posture, and which embedding model to pick
5. [Federation Exchange](federation.md): Bridging external identity providers to Databricks for users who don't have workspace accounts
5a. [Federation Personas and Use-Case Patterns](federation-personas-patterns.md): A reusable role taxonomy for external-user federation, the role to IdP-group to service-principal to UC-group chain, and multi-group resolution. Use it to decide which roles you need before configuring policy.
6. [GCP Workload Identity Federation](gcp-workload-identity-federation.md): Any GCP workload (GKE, Cloud Run, Compute Engine, etc.) to Databricks via RFC 8693, no secrets required
7. [Service Identity and Audit Architecture](service-identity-and-audit.md): Reference deep-dive on which identity each AI service honors, the three proxy types, confused-deputy prevention, and the platform-plus-application audit model.

## The Key Insight

AuthN establishes identity. AuthZ enforces policy. They compose but never substitute for each other:

```
User authenticates via IdP (AuthN)
       |
       v
Token carries identity to Databricks (OAuth, SAML, OIDC)
       |
       v
Unity Catalog evaluates: can this identity access this resource? (AuthZ)
       |
       v
Row filters, column masks, grants fire at the SQL engine level
```

Every AI service on Databricks (Genie Agents, Agent Bricks, Model Serving, Apps, custom MCP) ultimately issues SQL. The SQL engine enforces AuthZ. New AI services inherit authorization on day one.

## Related Pillars

- [Observability](../observability/): Audit records which identity did what
- [Harness](../harness/): How identity and observability show up in the agent runtime
- Databricks docs: [row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/) fire after identity is established; [Unity Catalog external connections](https://docs.databricks.com/aws/en/query-federation/http) control which identities can call external services
