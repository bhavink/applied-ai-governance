# Data Governance

> **Pillar 3** -- Given this identity, what data can they see?

Four layers of access control, all enforced by the SQL engine. No application can bypass them. No new AI service needs to integrate with them.

## Reading Order

1. [UC Authorization](uc-authorization.md) -- Four-layer access control: privileges, ABAC, row filters, column masks. Industry vertical patterns.
2. [UC Policy Design](uc-policy-design.md) -- When `current_user()` and `is_member()` work (and don't) across execution contexts
3. [Genie Authorization Cookbook](genie-authorization-cookbook.md) -- Multi-team Genie access for 1000+ users with complex UC governance

## Key Concepts

- **Row Filters**: `is_member('west_sales')` restricts rows by group membership. Silent -- returns fewer rows, not errors.
- **Column Masks**: `CASE WHEN is_member('finance') THEN margin_pct ELSE NULL END`. Sensitive columns return NULL for unauthorized identities.
- **ABAC Governed Tags**: Dynamic access based on classification tags (PII, HIPAA, confidential).
- **SP Identity Gap**: Under M2M/Federation, `current_user()` returns the SP UUID, not the human. Use `is_member()` for group-based governance.

## Related Pillars

- [Identity](../identity/) -- Identity model determines how `current_user()` and `is_member()` resolve
- [Tool Governance](../tool-governance/) -- USE CONNECTION extends data governance to external APIs
- [Observability](../observability/) -- Platform audit records every governance decision the SQL engine made
