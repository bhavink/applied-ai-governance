# Identity & Access Control

> **Pillar 2** -- Who is making the request, and what capabilities does their token grant?

Three identity models, one governance plane. Every AI service on Databricks uses one of these patterns to establish who the caller is.

## Reading Order

1. [Authentication Patterns](authentication-patterns.md) -- The three universal patterns (OBO, M2M, Federation) with code examples
2. [OBO vs M2M Decision Matrix](obo-vs-m2m-decision-matrix.md) -- Quick decision tree, per-service examples, anti-patterns
3. [Authorization Flows](authorization-flows.md) -- Hop-by-hop header traces for single/dual/triple proxy architectures
4. [Federation Exchange](federation-exchange.md) -- External IDP token exchange, role-based SPs, governance enforcement points
5. [Identity Reference](identity-reference.md) -- 16-service identity map, product gaps, audit decorator, chain-of-custody SQL

## Key Concepts

- **OBO (U2M)**: Platform acts on behalf of a known human. `current_user()` = human email.
- **M2M**: Service principal authenticates with its own credentials. No human in the loop.
- **Federation**: External IDP token exchanged for a role-based SP token. Users don't have Databricks accounts.
- **OAuth Scopes**: Capability ceiling per token (`sql`, `genie`, `serving` -- never `all-apis`).
- **Confused Deputy Defense**: Two independent enforcement layers (app RBAC + UC grants).

## Related Pillars

- [Data Governance](../data-governance/) -- Once identity is established, what data can they see?
- [Tool Governance](../tool-governance/) -- Once identity is established, what tools can they use?
- [Observability](../observability/) -- How do you audit what each identity did?
