# Identity & Access Control

> **Pillar 2**: Who is making the request, and what can they do?

Two distinct concepts, often conflated:

- **Authentication (AuthN)**: Who are you? Delegated to Identity Providers. Databricks does not manage passwords or user directories.
- **Authorization (AuthZ)**: What can you do? This is where Databricks plays. Unity Catalog is the authorization engine for all AI services.

## Reading Order

1. [Authentication](authentication.md): How AuthN works across clouds (brief, links to official docs)
2. [Authorization](authorization.md): The three token patterns, UC governance, OAuth scopes, service principals
3. [U2M from External Apps](u2m-external-obo.md): OBO from a non-Databricks app when users are already provisioned in the workspace
4. [Federation Exchange](federation.md): Bridging external identity providers to Databricks for users who don't have workspace accounts
5. [GCP Workload Identity Federation](gcp-workload-identity-federation.md): Any GCP workload (GKE, Cloud Run, Compute Engine, etc.) to Databricks via RFC 8693, no secrets required

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

Every AI service on Databricks (Genie, Agent Bricks, Model Serving, Apps, custom MCP) ultimately issues SQL. The SQL engine enforces AuthZ. New AI services inherit authorization on day one.

## Related Pillars

- [Data Governance](../data-governance/): Row filters, column masks, ABAC that fire after identity is established
- [Tool Governance](../tool-governance/): USE CONNECTION controls which identities can call external services
- [Observability](../observability/): Audit records which identity did what
