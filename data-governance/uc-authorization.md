# Authorization with Unity Catalog

> **Reference architecture for Unity Catalog governance across Databricks AI products.**
>
> **Prerequisite**: Read [UC Policy Design](uc-policy-design.md) for how `current_user()` and `is_member()` behave across all execution contexts (Genie OBO, Agent Bricks, M2M, direct SQL).

---

## Disclaimers

- Links default to **AWS Databricks docs**. Use the cloud selector dropdown for Azure or GCP variants.
- This guide is **practical guidance**, not official Databricks positions. Verify current syntax in [official docs](https://docs.databricks.com).

---

## Four Layers of Access Control

| Layer | Question Answered | Mechanisms |
|-------|-------------------|------------|
| **1. Workspace Restrictions** | WHERE can users access data? | Workspace bindings on catalogs, external locations, storage credentials |
| **2. Privileges & Ownership** | WHO can access WHAT? | GRANTs (SELECT, MODIFY, etc.), object ownership, admin roles |
| **3. ABAC Policies** | WHAT data based on tags? | Governed tags + policies with UDFs for dynamic enforcement |
| **4. Table-Level Filtering** | WHAT rows/columns visible? | Row filters, column masks, dynamic views |

Layers evaluate top-down: workspace binding first, then GRANTs, then ABAC tag policies, then row/column filters. All four must pass for data to be returned.

**Docs**: [Access Control in UC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control), [UC Overview](https://docs.databricks.com/aws/en/data-governance/unity-catalog/index.html)

---

## UC Hierarchy

Metastore > Catalog > Schema > Table > Column/Row. Permissions granted at a higher level cascade downward. More specific permissions override general ones.

| Level | Permissions Granted | Example |
|-------|---------------------|---------|
| **Catalog** | USE CATALOG, CREATE SCHEMA | `finance_prod` |
| **Schema** | USE SCHEMA, CREATE TABLE | `finance_prod.accounting` |
| **Table** | SELECT, INSERT, UPDATE, DELETE, MODIFY | `finance_prod.accounting.transactions` |
| **Column** | Column masks | `transactions.amount` |
| **Row** | Row filters | Individual records |

**Docs**: [UC Object Model](https://docs.databricks.com/aws/en/data-governance/unity-catalog/best-practices.html)

---

## Permission Model: GRANTs

```sql
-- Three-step grant pattern (all three required for table access)
GRANT USE CATALOG ON CATALOG finance_prod TO `analysts`;
GRANT USE SCHEMA ON SCHEMA finance_prod.accounting TO `analysts`;
GRANT SELECT ON TABLE finance_prod.accounting.transactions TO `analysts`;
```

| Role | Can Grant On | Scope |
|------|--------------|-------|
| **Metastore Admin** | All objects | Account-wide |
| **Catalog Owner** | Catalog and children | Specific catalog |
| **Schema Owner** | Schema and children | Specific schema |
| **Table Owner** | Specific table | Individual table |

**Docs**: [GRANT Statement](https://docs.databricks.com/aws/en/sql/language-manual/security-grant.html), [UC Privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/index.html)

---

## Row-Level Security: Row Filters

Row filters restrict which rows a user sees. The filter function evaluates per row and returns TRUE/FALSE. Users are unaware of filtered-out rows.

```sql
-- Pattern: create filter function, then apply to table
CREATE FUNCTION schema.filter_fn(col DATA_TYPE)
RETURNS BOOLEAN
RETURN condition_using_current_user_or_is_member;

ALTER TABLE schema.table
  SET ROW FILTER schema.filter_fn ON (col);
```

### Common Row Filter Patterns

| Pattern | Logic | Use Case |
|---------|-------|----------|
| **User-based** | `column = current_user()` | Personal data (own records) |
| **Group-based** | `is_member(column)` | Department access |
| **Hierarchical** | `owner = current_user() OR manager = current_user()` | Manager/employee |
| **Time-based** | `date_column >= current_date() - 365` | Historical restrictions |
| **Multi-tenant** | `tenant_id = extract_tenant(current_user())` | SaaS isolation |
| **Compliance bypass** | `is_member('compliance') OR condition` | Audit/compliance sees all |

**Docs**: [Row Filters and Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)

---

## Column-Level Security: Column Masks

Column masks transform column values based on user identity. The `VALUE` keyword represents the original column value.

```sql
-- Pattern: CASE expression with group-based disclosure
CREATE FUNCTION schema.mask_fn()
RETURNS DATA_TYPE
RETURN CASE WHEN is_member('admins') THEN VALUE
            ELSE '***' END;

ALTER TABLE schema.table
  ALTER COLUMN col SET MASK schema.mask_fn;
```

### Common Column Mask Patterns

| Pattern | Masking Logic |
|---------|---------------|
| **Full redaction** | `'***'` or `NULL` |
| **Partial redaction** | `CONCAT('***', SUBSTR(VALUE, -4))` |
| **Email masking** | `CONCAT('***@', SPLIT_PART(VALUE, '@', 2))` |
| **Hash masking** | `SHA2(VALUE, 256)` |
| **Role-based** | Multiple `WHEN is_member()` conditions |

**Docs**: [Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)

---

## Attribute-Based Access Control (ABAC)

> **Public Preview.**

ABAC is a centralized, tag-based policy framework. Instead of configuring filters on each table, you define policies that reference governed tags. Databricks recommends ABAC for governance at scale.

### ABAC vs Table-Level Filtering

| Aspect | ABAC (Recommended) | Table-Level Filters |
|--------|---------------------|---------------------|
| **Scope** | Centralized, tag-driven | Per-table configuration |
| **Scalability** | Define once, applies to thousands of tables | Must configure each table |
| **Updates** | Change tag = access changes instantly | Must update each table |
| **Use When** | Centralized governance at scale | Per-table custom logic needed |

### How It Works

1. Define **governed tags** at account level with allowed values (e.g., `sensitivity: [low, medium, high, critical]`)
2. Apply tags to catalogs, schemas, or tables (tags inherit downward)
3. Create **UDFs** for filtering/masking logic
4. Create **ABAC policies** referencing tags and UDFs

Tags alone do not enforce access. ABAC policies do the enforcement.

### Limitations

- Requires Databricks Runtime 16.4+ or serverless
- Cannot apply policies directly to views (underlying tables are enforced)
- One row filter can resolve per table per user at runtime

**Docs**: [UC ABAC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac), [Governed Tags](https://docs.databricks.com/aws/en/admin/governed-tags/), [ABAC Tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac-tutorial.html)

---

## Dynamic Views

Use dynamic views when you need cross-table logic, complex aggregations, or conditional column selection that row filters and masks cannot express.

| Use Case | Row Filter/Mask | Dynamic View |
|----------|-----------------|--------------|
| Simple user/group check | Preferred | Overkill |
| Cross-table logic | Not possible | Use view |
| Complex aggregations | Not possible | Use view |
| Legacy migration | Requires table changes | Layer views on top |

```sql
-- Pattern: conditional visibility + row filtering in a single view
CREATE VIEW schema.dynamic_view AS
SELECT col1,
  CASE WHEN is_member('group') THEN col2 ELSE NULL END AS col2
FROM schema.base_table
WHERE owner_email = current_user() OR is_member('managers');
```

**Docs**: [Dynamic Views](https://docs.databricks.com/aws/en/data-governance/unity-catalog/create-views.html)

---

## UC Built-in Functions Reference

| Function | Returns | Use Case |
|----------|---------|----------|
| `current_user()` | STRING (email) | Row filter: `owner = current_user()` |
| `is_member('group')` | BOOLEAN | Column mask: `WHEN is_member('admins') THEN VALUE` |
| `current_catalog()` | STRING | Context-aware policies |
| `current_timestamp()` | TIMESTAMP | Time-based access |

### `is_member()` vs `current_user()` Under OBO

> Verified on Azure Databricks, March 2026. Applies to Genie, Databricks Apps, and any OBO path.

| Function | Evaluated as under OBO | Correct? |
|---|---|---|
| `current_user()` | The calling user's email | YES |
| `is_member('group')` | The SQL execution identity (e.g., Genie's service account) | NO for user-level checks |

**Rule**: Use `current_user()` for OBO-compatible access control. Replace `is_member()` patterns with an allowlist table lookup keyed on `current_user()`:

```sql
-- Replace is_member() with allowlist for OBO compatibility
CREATE FUNCTION masks.redact_obo(value DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN EXISTS (
  SELECT 1 FROM schema.viewers WHERE user_email = current_user()
) THEN value ELSE NULL END;
```

---

## Pattern Integration: Auth Patterns and UC

| Pattern | Identity in UC | Row Filters Evaluate As | Use When |
|---------|---------------|------------------------|----------|
| **Pattern 1 (M2M)** | Service Principal | SP identity (fixed) | Consistent automated access |
| **Pattern 2 (OBO)** | End User | User identity (per-user) | Personalized data access |
| **Pattern 3 (Manual)** | N/A | UC not involved | External APIs |

### Agent Bricks Integration

| Use Case | Auth Pattern | UC Integration |
|----------|--------------|----------------|
| Knowledge Assistant | Pattern 1 or 2 | Vector indexes governed by UC |
| Multi-Agent Supervisor | Pattern 2 (OBO) | Orchestrates Genie + agents |
| Code Your Own | Pattern 1, 2, or 3 | Full UC access via SDK |

**Docs**: [Agent Authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)

---

## Performance Considerations

| Operation | Overhead | Mitigation |
|-----------|----------|------------|
| Simple row filter | Low (5-10%) | Acceptable for most cases |
| Complex row filter | Medium (10-30%) | Simplify logic, use indexes |
| Multiple row filters | High (30%+) | Consolidate into single filter |
| Column mask | Low-Medium | Minimal impact |
| Dynamic view with aggregations | High | Use materialized views |

**Optimization strategies**: Partition tables by commonly filtered columns. Use materialized views for pre-filtered aggregates. Simplify filter logic (prefer `is_member(dept)` over complex concatenation patterns). Index commonly filtered columns.

---

## Best Practices

1. **Least privilege**: Grant minimum required permissions per group, not `ALL PRIVILEGES`
2. **Use groups, not individual users**: Manage group membership in IdP
3. **Document filter/mask logic**: Add `COMMENT` to filter functions explaining the access tiers
4. **Separate access control from business logic**: Row filters handle who sees what; queries handle what is relevant
5. **Test with multiple personas**: Regular user, manager, limited user, admin/compliance
6. **Regular audits**: Quarterly review of GRANT, row filter, and column mask configurations

---

## Troubleshooting

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| User sees 0 rows | Check GRANTs, row filter logic, group membership | Verify USE CATALOG + USE SCHEMA + SELECT; check filter function |
| Wrong mask applied | Check mask function conditions | Verify `is_member()` conditions and group membership |
| Performance degraded | Check filter complexity | Simplify, add materialized views, partition tables |
| Filter not applying | All users see all data | Run `DESCRIBE TABLE EXTENDED` to verify filter is set |

---

## Industry Vertical ABAC Patterns

### Data Model Patterns for Access Control

| Pattern | Description | Best For |
|---|---|---|
| **Team/Region-level** | Rows contain territory or team column; access via group membership | Regional sales, geographic compliance |
| **Individual-level** | Rows tied to a specific user (email); only owner sees records | CRM "my accounts", patient-provider |
| **Hierarchical** | Managers see reports' data; directors see managers' data | Management dashboards |
| **Attribute-based (ABAC)** | Decisions combine role + department + clearance + sensitivity | Regulated industries |

### The Governance Column Pattern

Add explicit columns whose sole purpose is supporting access control policies (`region`, `sensitivity_level`, `data_owner_email`, `department`). Populate at ingestion time, not retroactively. Denormalize governance columns onto the table rather than requiring JOINs in filter functions.

### Healthcare (HIPAA)

| Role | Row Access | Column Access |
|---|---|---|
| Treating provider | Assigned patients only | Full clinical data |
| Department nurse | Same department patients | Clinical, no billing |
| Billing specialist | All patients in facility | Billing only, no clinical notes |
| Hospital admin | All patients, all facilities | Aggregates only, no PHI |
| External auditor | Sampled records | De-identified |

Row filter pattern: CASE expression checking `is_account_group_member()` for each role tier, matching on `dept_id` and `facility_id`. Column mask: redact patient name for billing roles, show to clinical roles.

### Financial Services

| Role | Row Access | Column Access |
|---|---|---|
| Branch advisor | Their clients only | Full account details |
| Branch manager | All clients in branch | Full account details |
| Regional director | All branches in region | Aggregated, no PII |
| Compliance officer | All accounts | Full (audit purpose) |

Row filter pattern: region-based CASE matching `is_account_group_member('region-*')`. Column mask: account numbers show last 4 digits except for compliance and advisors.

### Retail / CPG

| Role | Row Access | Column Access |
|---|---|---|
| Store manager | Their store only | Full store metrics |
| District manager | All stores in district | Full metrics |
| Regional VP | All stores in region | Full metrics |
| Franchise partner (federated) | Their franchise stores | Revenue, no cost data |

Row filter pattern: region and franchise-based CASE. Column mask: hide cost/margin from franchise partners.

### SaaS Multi-Tenant

Every table has `tenant_id` as a non-nullable governance column. Row filter maps `is_account_group_member('tenant-*')` to `tenant_id`. Column mask gates premium metrics by subscription tier group membership.

### Channel Partner / Federation

When external users authenticate via token exchange, they map to a Databricks SP. `current_user()` returns the SP UUID, not the original email. Use `is_account_group_member()` for group-based row filters (SP can be in Databricks groups). For individual-level filtering, use a mapping table with `session_user()` lookup.

---

## Service Principal Identity Under Token Exchange

### Access Pattern Compatibility

| Access Pattern | Works with SP Token Exchange? | Why |
|---|---|---|
| `is_account_group_member('group')` | YES | SP can be a member of groups |
| `session_user() = 'user@partner.com'` | NO | Returns SP UUID |
| `owner_email = current_user()` | NO | Returns SP UUID |
| Parameter passing via app layer | YES | App sends user context |

### Strategy Decision Framework

```
Do all users in the same role see the same rows?
  +-- YES --> Group-Based: is_account_group_member() in row filters
  +-- NO  --> Does the user need to see only "their" records?
               +-- YES, platform enforcement required --> Mapping Table + EXISTS
               +-- YES, app-layer enforcement OK --> App Parameter Passing
               +-- MIXED --> Hybrid (row filter for role, app for individual)
```

---

## UDF Best Practices

**Do**: Simple CASE statements, deterministic logic, SQL UDFs, test on 1M+ rows.

**Do not**: External API calls, nested UDFs, complex subqueries (mapping table is the accepted exception), Python UDFs (10-100x slower), non-deterministic logic.

### Performance Hierarchy

```
Fastest to slowest:
1. is_account_group_member()    ~0ms (cached per session)
2. Simple column comparison     ~0ms per row
3. CASE with 5-10 branches     ~0ms per row
4. EXISTS with small lookup     ~1-10ms per query
5. EXISTS with large mapping    ~10-100ms per query
6. Python UDF                   10-100x slower than SQL
7. External API call            DO NOT DO THIS
```

---

## Access Control Pattern Comparison

| Pattern | Granularity | Complexity | Performance | Works with SPs? | Platform Enforced? |
|---|---|---|---|---|---|
| **Group + is_account_group_member()** | Team/Region | Low | Good | Yes | Yes |
| **current_user() / session_user()** | Individual | Low | Good | No (SP UUID) | Yes |
| **App-layer parameter passing** | Individual | Medium | Good | Yes (app-enforced) | No |
| **Mapping table + EXISTS** | Individual | High | Moderate | Partial (per-SP) | Yes |
| **ABAC via governed tags** | Flexible | High (initial) | Moderate | Yes | Yes |
| **Dynamic views** | Flexible | Medium | Good | Yes | Yes |
