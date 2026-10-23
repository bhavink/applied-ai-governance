# Data Governance

> **Pillar 3**: Once identity is established, what data can this identity see, and at what granularity?

Identity (Pillar 2) establishes *who* is asking. Data governance decides *which rows and
columns* they may see. In Unity Catalog this is enforced at the SQL engine, so every AI
service that ultimately issues SQL (Genie Agents, Agent Bricks, Model Serving, custom MCP) inherits
the same row filters and column masks with no per-service work.

## Reading Order

1. [Access Control Patterns](access-control-patterns.md): Row filters, column masks, ABAC via
   governed tags, and the data-model patterns behind them (team/region, individual,
   hierarchical, attribute-based). For federated external users, the repository standard is
   `current_oauth_custom_identity_claim()` plus a governed entitlement table and a fail-closed
   Unity Catalog row filter. See [External-User Authorization](../identity/external-user-authorization.md).

## The Key Insight

Govern the data, not the tool. A row filter or column mask attached to a table fires the same
way regardless of which AI product issued the query. Model the governance columns once, attach
the policy once, and every current and future AI service on top of that data is governed on
day one.

## Presentations

- [UC Governance](https://bhavink.github.io/applied-ai-governance/presentations/uc-governance.html): row filters, column masks, ABAC, and governed tags as the enforcement layer.

## Related Pillars

- [Identity & Access Control](../identity/): establishes the acting identity that data
  governance then evaluates. The choice of per-user vs role-based federation directly
  determines whether individual-level row filters are even possible.
- [Observability & Audit](../observability/): records which identity read which data, and how
  to attribute an SP-executed query back to the human who initiated it.
