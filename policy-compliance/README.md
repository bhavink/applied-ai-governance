# Policy & Compliance

> **Pillar 6** -- Is the governance codified, repeatable, and provable?

Governance-as-SQL. The policy IS the SQL, not a translation of policy into code. Declarative, versionable, queryable, auditable.

## Status

Future work. This pillar will cover:

- **Governance-as-code patterns** -- SQL grant scripts in git, reviewed via PR, applied via CI/CD
- **Compliance evidence generation** -- Automated proof of access controls from `SHOW GRANTS` and `system.access.audit`
- **Policy drift detection** -- Compare declared policy (git) vs actual state (UC) and alert on divergence
- **Regulatory mapping** -- How the seven pillars map to SOC 2, HIPAA, GDPR, and industry-specific requirements
- **Access review workflows** -- Periodic recertification of grants using system table queries

## Key Principle

```sql
-- The entire access control policy for a role, in SQL
SHOW GRANTS ON CATALOG my_catalog;
SHOW GRANTS ON CONNECTION github_api;
```

SQL has been the lingua franca of data access control for 50 years. It will outlast any policy engine, any YAML schema, any proprietary policy language.

## Related Pillars

- [Observability](../observability/) -- Audit is the evidence; compliance is the interpretation
- [Data Governance](../data-governance/) -- Row filters and column masks are the policies being proven
- [Governance Framework](../GOVERNANCE-FRAMEWORK.md) -- Policy & Compliance is Pillar 6 in the seven-pillar model
