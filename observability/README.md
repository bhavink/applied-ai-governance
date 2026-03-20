# Observability & Audit

> **Pillar 5**: What happened, and can you prove it?

Three complementary audit layers. Platform audit captures what the system sees. Application audit captures what the user intended. MLflow traces capture the full request lifecycle. Only the correlation of all three gives the complete chain of custody.

## Reading Order

1. [Audit Reference](audit-reference.md): Two-layer audit model, scorer patterns, dashboard guide, correlation queries, alert SQL

## Key Concepts

- **Chain of Custody**: `human -> tool -> SQL -> data`, correlated across all three layers by `request_id`.
- **Platform Audit**: `system.access.audit`, every SQL query, UC operation, identity, timestamp. The ground truth.
- **App Audit**: Custom Delta table with `@audited_tool` decorator, capturing tool calls, human email, latency, and errors.
- **MLflow Traces**: Full request/response spans with tags, token usage, quality scores.
- **Silent vs Loud**: Data governance failures are silent (fewer rows, NULL columns). Capability failures are loud (403, ACCESS_DENIED).

## Related Pillars

- [Identity](../identity/): Audit records which identity made each request
- [Data Governance](../data-governance/): Platform audit records every row filter and column mask evaluation
- [Policy & Compliance](../policy-compliance/): Audit is the evidence layer for compliance
