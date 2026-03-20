# Unity Catalog Governance

> UC enforces access at the SQL engine level. No application can bypass it. No new AI service needs to integrate with it.

## Four Layers of Access Control

| Layer | Question | Mechanism |
|-------|----------|-----------|
| **1. Workspace Restrictions** | WHERE can they access? | Workspace bindings on catalogs |
| **2. Privileges** | WHO can access WHAT? | GRANTs (SELECT, MODIFY, EXECUTE) |
| **3. ABAC Policies** | WHAT data by classification? | Governed tags + policy UDFs |
| **4. Row/Column Filters** | WHAT rows and columns? | Row filters, column masks |

All four layers evaluate in order. All must pass for data to be returned.

Reference: [Access Control in UC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control), [UC Overview](https://docs.databricks.com/aws/en/data-governance/unity-catalog/index.html)

## UC Hierarchy

Metastore > Catalog > Schema > Table > Column/Row. Permissions cascade downward.

```sql
-- Three grants required for table access
GRANT USE CATALOG ON CATALOG my_catalog TO `analysts`;
GRANT USE SCHEMA ON SCHEMA my_catalog.accounting TO `analysts`;
GRANT SELECT ON TABLE my_catalog.accounting.transactions TO `analysts`;
```

Reference: [GRANT Statement](https://docs.databricks.com/aws/en/sql/language-manual/security-grant.html)

## Row Filters

Row filters restrict which rows a user sees. Users are unaware of filtered rows (silent enforcement).

```sql
CREATE FUNCTION schema.region_filter(region STRING)
RETURNS BOOLEAN
RETURN is_member(region) OR is_member('executives');

ALTER TABLE schema.deals SET ROW FILTER schema.region_filter ON (region);
```

| Pattern | Logic | Use Case |
|---------|-------|----------|
| User-based | `col = current_user()` | Personal records |
| Group-based | `is_member(col)` | Regional/team access |
| Hierarchical | `owner = current_user() OR is_member('managers')` | Manager visibility |
| Multi-tenant | `tenant_id = extract_tenant(current_user())` | SaaS isolation |

Reference: [Row Filters and Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)

## Column Masks

Column masks transform values based on identity. The `VALUE` keyword represents the original value.

```sql
CREATE FUNCTION schema.mask_margin()
RETURNS DOUBLE
RETURN CASE WHEN is_member('finance') THEN VALUE ELSE NULL END;

ALTER TABLE schema.deals ALTER COLUMN margin_pct SET MASK schema.mask_margin;
```

| Pattern | Masking Logic |
|---------|---------------|
| Full redaction | `NULL` or `'***'` |
| Partial | `CONCAT('***', SUBSTR(VALUE, -4))` |
| Role-based | Multiple `WHEN is_member()` branches |

## ABAC (Attribute-Based Access Control)

> Public Preview. Databricks recommends ABAC for governance at scale.

ABAC uses governed tags to drive centralized policies. Instead of configuring filters per table, define policies that reference tags. Tags classify; policies enforce.

| Aspect | ABAC | Table-Level Filters |
|--------|------|---------------------|
| Scope | Centralized, tag-driven | Per-table |
| Scale | Define once, applies everywhere | Must configure each table |
| Updates | Change tag, access changes instantly | Update each table |
| Use when | Centralized governance at scale | Per-table custom logic |

How it works: define governed tags (e.g., `sensitivity: [low, high, critical]`), apply to objects, create UDFs for logic, create ABAC policies referencing tags and UDFs.

Reference: [ABAC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac), [ABAC Tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial), [Governed Tags](https://docs.databricks.com/aws/en/admin/governed-tags/)

## The Critical Choice: `current_user()` vs `is_member()`

This is the single most important decision in UC policy design.

| Function | What it evaluates | Reliable under OBO? |
|----------|-------------------|---------------------|
| `current_user()` | The identity on the active SQL token | **Yes.** Always the human's email in OBO chains. |
| `is_member('group')` | SQL execution identity's group membership | **Not always.** In Genie/Agent Bricks, may evaluate the service layer, not the user. |

| Execution Context | `current_user()` | `is_member()` |
|-------------------|-------------------|----------------|
| Human in notebook/SQL editor | User email | User's groups |
| Genie Space (OBO) | User email | Execution context groups (may differ) |
| Agent Bricks supervisor (OBO) | User email | Execution context groups (may differ) |
| App SP (M2M) | SP client ID | SP's workspace groups |
| Custom MCP via Apps proxy | MCP app SP client ID | MCP SP's groups |

**The rule**: Use `current_user()` for OBO-compatible access control. Use `is_member()` when you control the executor (M2M SP).

### The Allowlist Table Pattern

When you need role-based access in OBO contexts, replace `is_member()` with a `current_user()` lookup:

```sql
CREATE TABLE governance.viewers (user_email STRING NOT NULL);

CREATE FUNCTION governance.can_view(val DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN EXISTS (
  SELECT 1 FROM governance.viewers WHERE user_email = current_user()
) THEN val ELSE NULL END;
```

This works across all contexts because `current_user()` always reflects the OBO caller's email.

### Combining Both Primitives

Most real policies need both: user-scoped access for individuals, role bypass for managers.

```sql
CREATE FUNCTION sales.filter_opps(rep_email STRING)
RETURNS BOOLEAN
RETURN is_member('executives') OR is_member('managers')
    OR rep_email = current_user();
```

In M2M: SP is in `executives`, `is_member()` passes, all rows visible. In OBO: `current_user()` = user's email, their rows visible. Both paths work correctly.

## Industry Patterns

| Industry | Row Filter Key | Column Mask Focus |
|----------|---------------|-------------------|
| Healthcare (HIPAA) | Patient assignment, department, facility | PHI redaction for non-clinical roles |
| Financial Services | Branch, region, client ownership | Account numbers, balances for non-advisors |
| Retail/CPG | Store, district, region, franchise | Cost/margin hidden from franchise partners |
| SaaS Multi-Tenant | `tenant_id` on every table | Premium metrics by subscription tier |
| Federation (external users) | `is_member()` on SP groups | Role-based column visibility |

The **governance column pattern**: add explicit columns (`region`, `sensitivity_level`, `data_owner_email`) whose sole purpose is supporting access control. Populate at ingestion time. Denormalize onto the table rather than requiring JOINs in filter functions.

## Performance

| Filter Type | Overhead | Guidance |
|-------------|----------|----------|
| Simple `is_member()` | Minimal (~0ms, cached per session) | Use freely |
| `current_user()` comparison | Minimal | Use freely |
| EXISTS with small lookup table | Low (1-10ms per query) | The allowlist pattern, acceptable |
| Complex multi-branch CASE | Low | Keep under 10 branches |
| Python UDF in a filter | 10-100x slower | Avoid |

Optimization: partition tables by commonly filtered columns. Simplify filter logic. Use SQL UDFs, not Python.

## Operational Notes

- **Group membership delay**: `is_member()` reflects changes within ~2 minutes. Start a new SQL session to pick up changes.
- **Workspace groups only**: `is_member()` checks workspace-level groups, not account-level. If you sync groups from your IdP at the account level, create parallel workspace groups.
- **UC function security**: Functions can be DEFINER (run as owner) or INVOKER (run as caller). For M2M, use INVOKER so the SP's identity drives policy evaluation.
- **Allowlist table access**: The lookup table itself needs proper UC grants. Treat it like any other governed object.

## Genie Space Patterns

Genie runs as the user (OBO). UC enforces row filters, column masks, and grants transparently on every generated SQL query.

### Access Control Layers for Genie

```
Layer 1: Genie Space membership (configured in UI)
Layer 2: UC grants (USE CATALOG, USE SCHEMA, SELECT)
Layer 3: Row filters (per-row, based on user identity)
Layer 4: Column masks (per-column value transformation)
```

### Three Tiers of Genie Governance

| Tier | Scale | Pattern |
|------|-------|---------|
| **Simple Multi-Team** | 3-5 teams, 50-150 users | Team-based row filters with executive bypass. Column masks for revenue precision by role. Single catalog, team-specific schemas. |
| **Enterprise Scale** | 50+ departments, 5000+ users | ABAC with governed tags (`sensitivity: [public, internal, confidential]`). Hierarchical access (employee > manager > director > executive). Materialized views for aggregates at scale. |
| **Multi-Agent Supervisor** | Multiple Genie Spaces behind a supervisor agent | Hybrid auth: M2M for intent classification, OBO for Genie routing (user token forwarded). Separate catalogs per domain. Per-domain row filters. |

### Key Genie Gotcha

`is_member()` in Genie OBO evaluates the SQL execution identity, not the calling user. Use `current_user()` + allowlist table for reliable group-based access in Genie.

### Genie Space Instructions

Provide role descriptions, common business term definitions, and column/table references in the Genie Space instructions field. Without good instructions, Genie generates incorrect SQL regardless of how well UC is configured.

### Common Issues

| Issue | Fix |
|-------|-----|
| User sees 0 rows | Check grants (USE CATALOG + USE SCHEMA + SELECT) and row filter logic |
| User sees too much data | Verify filter is applied (`DESCRIBE TABLE EXTENDED`), check for missing `ELSE FALSE` |
| `is_member()` wrong result | Replace with allowlist table + `current_user()` |
| Genie generates wrong SQL | Improve instructions with column names, business terms, role-specific examples |

Reference: [Genie Space](https://docs.databricks.com/aws/en/genie/)

---

## Related Databricks Documentation

- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html)
- [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- [Row Filters & Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)
- [ABAC Tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)
- [Governed Tags](https://docs.databricks.com/aws/en/admin/governed-tags/)
- [UC Privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/index.html)
