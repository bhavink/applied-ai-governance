# Data Governance

> **Pillar 3**: Given this identity, what data can they see?

Unity Catalog enforces data access at the SQL engine level. Every AI service on Databricks (Genie, Agent Bricks, Model Serving, Apps, custom MCP) ultimately issues SQL. The same row filters, column masks, and grants apply regardless of which service runs the query.

## Reading Order

1. [UC Governance](uc-governance.md): Four-layer access control, row filters, column masks, ABAC, identity functions, Genie patterns

## Key Concepts

- **Four layers**: Workspace bindings, privileges (GRANTs), ABAC policies, row/column filters. All four must pass.
- **Silent enforcement**: Row filters return fewer rows, column masks return NULL. No errors, no indication that data was restricted.
- **`current_user()` vs `is_member()`**: The single most important decision in UC policy design. `current_user()` propagates through OBO chains. `is_member()` evaluates the SQL execution identity (which may not be the calling user in Genie/Agent Bricks).
- **ABAC**: Tag-based centralized governance at scale. Tags classify, policies enforce. Public Preview.

## Related Pillars

- [Identity](../identity/): Identity model determines how `current_user()` and `is_member()` resolve
- [Tool Governance](../tool-governance/): USE CONNECTION extends data governance to external APIs
- [Observability](../observability/): Platform audit records every governance decision
