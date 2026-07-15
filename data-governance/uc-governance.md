<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: governance/unity-catalog.md, governance/abac.md, governance/row-filters.md, governance/column-masks.md, governance/governed-tags.md, governance/data-classification.md, governance/best-practices.md, governance/metastore-management.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/data-governance/unity-catalog/
  This file is auto-prepared and human-reviewed before publish.
-->

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

Metastore > Catalog > Schema > Table > Column/Row. Permissions cascade downward. A single metastore is scoped per cloud region and can be shared by multiple workspaces.

```sql
-- Three grants required for table access
GRANT USE CATALOG ON CATALOG my_catalog TO `analysts`;
GRANT USE SCHEMA ON SCHEMA my_catalog.accounting TO `analysts`;
GRANT SELECT ON TABLE my_catalog.accounting.transactions TO `analysts`;
```

Reference: [GRANT Statement](https://docs.databricks.com/aws/en/sql/language-manual/security-grant.html)

### BROWSE — Self-Service Catalog Discovery

`BROWSE` is a lightweight privilege that lets users discover catalog and schema structure without granting data access. Users can see catalog, schema, and table names; they cannot read rows, column values, or execute functions.

```sql
-- Allow all account users to browse the catalog structure
GRANT BROWSE ON CATALOG my_catalog TO `account users`;
```

| What BROWSE grants | What BROWSE does NOT grant |
|---|---|
| See catalog, schema, table, and view names | Read any data (SELECT) |
| Inspect table metadata (column names, data types) | Execute functions |
| Discover available objects for self-service | Access external locations or volumes |

**Governance pattern:** Grant `BROWSE` on shared catalogs to `account users` as the discovery floor. Then layer `SELECT` grants on specific schemas or tables to the groups that need data access. Pair this with an access-request destination — an email address, chat channel, or webhook configured on the catalog — so a user who finds a table they can't read has a direct path to request access instead of creating a shadow copy of the data.

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

A table can carry multiple row filter policies at once — all of them must evaluate to TRUE for a row to be visible (AND logic). Prefer one filter function with multiple conditions over stacking several filters, since each one adds evaluation overhead.

### Row Filter Patterns by Execution Context

| Context | `current_user()` | `is_member()` | Row filters fire as |
|---|---|---|---|
| SQL Warehouse (OBO + `sql` scope via UI) | Human email | Human's workspace groups | Individual user |
| SQL Warehouse (M2M) | SP UUID | SP's groups | Service principal |
| Genie Space (OBO) | Human email | **Genie service context** (not human) | User-level for `current_user()`; use lookup-table pattern instead of `is_member()` |
| Agent Bricks KA (OBO) | Human email | Human's workspace groups | Individual user |
| Agent Bricks MAS (OBO) | Human email | Human's workspace groups | Individual user |
| Databricks App (OBO via proxy) | Human email (if X-Forwarded-Access-Token used) | Human's workspace groups | Individual user |
| Databricks App (M2M) | SP UUID | SP's groups | Service principal |
| Custom MCP Server (M2M) | SP UUID | SP's groups | Service principal — app filters by `X-Forwarded-Email` |

### Verification Queries

```sql
-- Confirm what identity UC sees
SELECT current_user() AS who_am_i, session_user() AS session;

-- Verify row filter function is attached
DESCRIBE TABLE EXTENDED my_catalog.sales.opportunities;

-- Check what rows a specific identity sees (run as that user or SP)
SELECT COUNT(*) FROM my_catalog.sales.opportunities;
-- Compare to unfiltered count (as admin):
SELECT COUNT(*) FROM my_catalog.sales.opportunities WITH (NO ROW FILTER);
-- Note: WITH (NO ROW FILTER) requires OWNER on the table
```

### Performance Considerations

| Factor | Impact |
|---|---|
| Filter function complexity | Simple `is_member()` checks: <1ms overhead. Subqueries against lookup tables: 5-50ms depending on table size. |
| Number of groups checked | Each `is_member()` call is a group membership lookup. Minimize OR chains; use a lookup table for >5 groups. |
| Row filter on large tables | Filter applies per row. On billion-row tables, use partition pruning WHERE possible. |
| Multiple filters on one table | AND logic (all must pass). Each adds overhead. Prefer one filter with multiple conditions. |

### Row Filter Gotchas

> **Key nuance:** `is_member()` in OBO paths (Genie, Agent Bricks) evaluates the execution service identity, not the calling user. Design for it upfront by using `current_user()` + an allowlist table for any policy that needs group-style logic in those contexts.

| Issue | Impact | Fix |
|---|---|---|
| `is_member()` evaluates the execution service identity in OBO paths | Group-based row filters can miss the human caller's groups when Genie or Agent Bricks executes the query, with no error surfaced. | Use `current_user()` + allowlist table lookup. `current_user()` always resolves to the human caller's email in OBO chains. |
| `is_member()` only checks workspace-level groups | Account-level groups return false | Use `is_account_group_member()` or lookup table |
| Row filter on a view is not inherited from base table | View needs its own filter | Apply filters to both table and view |
| Filter function references deleted group | `is_member('gone')` returns false for everyone | Monitor for 0-row results |
| SP-executed queries bypass per-user filters | M2M sees all rows matching SP identity | Design SP-level filters or use OBO |

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

### Column Mask Pattern Library

```sql
-- Pattern 1: NULL for unauthorized
CREATE OR REPLACE FUNCTION masks.mask_salary(salary DOUBLE)
RETURNS DOUBLE
AS (CASE WHEN is_member('hr_team') OR is_member('managers') THEN salary ELSE NULL END);

-- Pattern 2: Partial reveal (last 4 digits)
CREATE OR REPLACE FUNCTION masks.mask_ssn(ssn STRING)
RETURNS STRING
AS (CASE WHEN is_member('hr_compliance') THEN ssn ELSE CONCAT('***-**-', RIGHT(ssn, 4)) END);

-- Pattern 3: Email masking (domain only)
CREATE OR REPLACE FUNCTION masks.mask_email(email STRING)
RETURNS STRING
AS (CASE WHEN is_member('admins') THEN email
    WHEN current_user() = email THEN email
    ELSE CONCAT('***@', SPLIT_PART(email, '@', 2)) END);

-- Pattern 4: Constant redaction
CREATE OR REPLACE FUNCTION masks.redact_pii(value STRING)
RETURNS STRING
AS (CASE WHEN is_member('pii_authorized') THEN value ELSE 'REDACTED' END);

-- Pattern 5: Lookup table (for account-level groups)
CREATE OR REPLACE FUNCTION masks.mask_phone(phone STRING)
RETURNS STRING
AS (CASE WHEN current_user() IN (SELECT email FROM authorized_viewers) THEN phone ELSE NULL END);
```

A mask function can call another mask function to chain transformations — keep the chain shallow, since each hop adds evaluation cost. Row filters and column masks compose freely: a user can be row-filtered and column-masked on the same query.

## ABAC (Attribute-Based Access Control)

> Databricks recommends ABAC for governance at scale.

ABAC uses governed tags to drive centralized policies. Instead of configuring filters per table, define policies that reference tags. Tags classify; policies enforce.

| Aspect | ABAC | Table-Level Filters |
|--------|------|---------------------|
| Scope | Centralized, tag-driven | Per-table |
| Scale | Define once, applies everywhere | Must configure each table |
| Updates | Change tag, access changes instantly | Update each table |
| Use when | Centralized governance at scale | Per-table custom logic |

How it works: define governed tags (e.g., `sensitivity: [low, high, critical]`), apply to objects, create UDFs for logic, create ABAC policies referencing tags and UDFs.

### Policy Attachment Levels

An ABAC policy (row filter, column mask, or GRANT policy) can attach at the level that matches the scope of the rule:

| Level | Behavior |
|---|---|
| Table | Applies to that specific table, materialized view, or streaming table |
| Schema | Attaches once and evaluates automatically for every matching object in the schema |
| Catalog | Attaches once and evaluates for every matching object across the whole catalog |

A single schema- or catalog-level policy expression can govern an entire catalog of tables without per-table DDL — the policy fires whenever an object carries the targeted governed tag, including tables created after the policy was defined.

### GRANT Policies

ABAC also supports **GRANT policies**, which dynamically grant `EXECUTE` privileges (for example, on models) based on tag attributes rather than a static per-principal GRANT. This extends the same tag-driven model from row/column security into privilege delegation. Syntax is evolving — check current docs for the latest DDL.

### Runtime Requirements

- Requires Databricks Runtime 15.4 LTS+ or serverless compute
- Requires **Standard** or **Dedicated** access mode compute (no-isolation/legacy single-user clusters bypass UC enforcement entirely)
- Classify and protect the underlying base tables rather than views or metric views — ABAC policies attach to tables, so views should inherit protection by querying protected tables underneath
- Time travel (`AS OF`) and cloning on ABAC-protected tables require the caller to be explicitly excluded from the policy
- Design Vector Search indexing around non-ABAC-protected source tables, or apply governance at the point where the index is queried

### Data Classification — The ABAC Input

Auto-classification uses an agentic scanning system to sample table columns and detect PII/PHI/PCI patterns using built-in semantic detectors (email, SSN, credit card, DoB, passport, IBAN, phone, IP address, street address). Results are written as `databricks:classifier:*` tags, or as `class.*` system-governed tags depending on configuration — check both namespaces when writing ABAC policies.

Classification is enabled per catalog (Default / Active / Inactive, overriding the metastore-level setting) or, for broad coverage, at the workspace level so every eligible catalog is scanned without per-catalog opt-in.

Two modes control how results become tags:

| Mode | Behavior |
|---|---|
| Manual review (default) | Classification runs; a data steward reviews and confirms results in Catalog Explorer before tags are applied |
| Automatic tagging | Tags are applied without manual review as new columns are scanned (typically within 24 hours of table creation) |

**Governance workflow:**
1. **Enable** classification at the metastore or catalog level
2. **Scan** runs automatically on new and existing tables
3. **Review** results via `system.information_schema.column_tags`, or monitor scan activity via `system.data_classification.results`
4. **Apply** column masks to classified columns
5. **Alert** on classified columns that have no mask applied yet

Classification does NOT automatically apply masks — it identifies; you enforce. The classification UI also surfaces **User Access (last 7 days)** metrics — distinct users touching masked vs. unmasked data by classification type — to help prioritize which columns to mask first. Individual detections can be dismissed from Catalog Explorer to correct false positives; a dismissed detection is excluded from future scans.

```sql
-- Find all PII columns without masks
SELECT t.catalog_name, t.schema_name, t.table_name, t.column_name, t.tag_value AS pii_type
FROM system.information_schema.column_tags t
LEFT JOIN system.information_schema.column_masks m
  ON t.catalog_name = m.catalog_name
  AND t.schema_name = m.schema_name
  AND t.table_name = m.table_name
  AND t.column_name = m.column_name
WHERE t.tag_name = 'databricks:classifier:pii_type'
  AND m.mask_function IS NULL;
```

Reference: [ABAC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac), [ABAC Tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial), [Data Classification](https://docs.databricks.com/aws/en/data-governance/unity-catalog/data-classification), [Governed Tags](https://docs.databricks.com/aws/en/admin/governed-tags/)

### Governed Tags — The ABAC Primitive

Tags are key-value metadata on UC securables (catalogs, schemas, tables, columns, volumes). Governed tags add administrator-defined policy on top of plain tags: who can assign a tag, and what values are permitted.

| Behavior | Detail |
|---|---|
| Propagation | Parent tags inherit downward (catalog → schema → table) as read-only copies |
| Column tags | Columns do **not** inherit tags from parent objects — set column-level tags directly with `ALTER TABLE ... ALTER COLUMN ... SET TAGS` |
| Override | Child can override an inherited tag value; it cannot remove an inherited tag — unset it at the parent to remove it everywhere |
| Privilege | `APPLY TAG` is separate from data access — data stewards tag, analysts query |
| Queryable | `system.information_schema.column_tags`, `table_tags`, `schema_tags`, `catalog_tags` |
| System tags | Databricks maintains reserved, write-protected tags such as `system.certification_status` (certified/deprecated) and the `class.*` PII family — only Databricks systems or account admins can write these |
| Account limits | Up to 1,000 governed tags per account; up to 50 allowed values per tag |

```sql
-- Tag a table
ALTER TABLE catalog.schema.employees SET TAGS ('sensitivity' = 'pii', 'domain' = 'hr');

-- Tag a column directly (does not inherit from the table)
ALTER TABLE catalog.schema.employees ALTER COLUMN ssn SET TAGS ('pii_type' = 'ssn');

-- Query all tags with inheritance
SELECT tag_name, tag_value, inherited_from_name, inherited_from_type
FROM system.information_schema.column_tags
WHERE catalog_name = 'my_catalog' AND table_name = 'employees';
```

The governance pattern: classify columns with tags, write policy functions that reference tags (or use ABAC policies), and tag-driven governance scales without per-table configuration.

## The Account vs Workspace Group Problem

Three distinct failures when groups are misconfigured:

| Failure | Cause | Symptom |
|---|---|---|
| Account-level group invisible to `is_member()` | `is_member()` checks workspace groups only | Row filter returns 0 rows for everyone |
| Account-level group invisible to `is_account_group_member()` when group not assigned to workspace | Group exists at account level but not assigned to workspace | Same as above |
| Genie OBO evaluates service context | `is_member()` checks session_user's groups, which is Genie's identity | Even workspace-level groups fail |

### Alternative Patterns

**1. Lookup table (recommended)**
```sql
-- Replace is_member() with current_user() + lookup
CREATE OR REPLACE FUNCTION filters.region_filter(region STRING)
RETURNS BOOLEAN
AS (current_user() IN (SELECT email FROM region_access WHERE access_region = region));
```

**2. Workspace group mirroring**
Sync account-level groups to workspace-level via SCIM or IdP sync. Adds operational overhead — prefer account-level SCIM as the primary provisioning path and keep workspace-level group sync as a narrow bridge, not a parallel system.

**3. Explicit email allowlist**
Hardcode emails in the filter function. Does not scale but works for small, stable groups.

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

## Metastore Management

A Unity Catalog metastore is the top-level container for all data assets in a cloud region — one metastore typically covers a region, and multiple workspaces can share it.

```
Databricks Account
└── Metastore (1 per region, usually)
    ├── External Locations (cloud storage mounts)
    ├── Storage Credentials (cloud auth for storage)
    ├── Connections (federated external systems)
    ├── Catalogs
    │   └── Schemas → Tables, Views, Functions, Volumes
    └── Workspace Bindings (which workspaces see this metastore)
```

### Admin Roles Are Distinct

| Role | Scope | What They Can Do |
|---|---|---|
| Account Admin | Databricks account | Create/delete metastores, assign metastore admins, manage users |
| Metastore Admin | Metastore | Manage external locations, storage credentials, connections; assign catalog ownership; view system tables |
| Workspace Admin | Single workspace | Assign metastore to workspace, manage workspace-level settings |
| Data/Catalog Owner | Specific object | GRANT/REVOKE on objects they own |

Account admin and metastore admin are separate roles — being one does not automatically grant the other. Assign metastore admin explicitly to the team that owns UC governance day to day.

### Storage Root and Workspace Bindings

The storage root is a cloud storage path set at metastore creation for managed table data and metastore metadata — plan it carefully, since it cannot be changed after creation (only removed and re-added, with existing catalogs falling back to an auto-created external location pointing at the prior path).

Workspace bindings control which workspaces can see a metastore; catalog-level bindings narrow this further to specific catalogs per workspace. Account admins can turn on **automatic metastore assignment** so new workspaces in a region attach to the metastore automatically — this also auto-creates a workspace catalog with default object-creation privileges for all workspace users, so review and tighten those defaults before enabling it in a production account.

### Metastore Strategy

| Pattern | Description | Tradeoffs |
|---|---|---|
| One metastore, multiple catalogs | `dev`, `staging`, `prod` catalogs in one metastore | Simple; strict workspace binding keeps prod isolated |
| One metastore per environment | Separate metastores per environment | Stronger isolation; more admin overhead, needs cross-metastore sharing for any shared data |
| One metastore per business unit | Each BU has its own metastore | Maximum isolation; best reserved for regulated environments |

**Recommendation for most teams**: one metastore, multiple catalogs, with strict workspace binding so a production workspace only sees the production catalog. For data that needs to move between metastores or regions, use Delta Sharing / OpenSharing rather than registering the same external table in more than one metastore — cross-metastore external table registration causes schema drift, since a change in one metastore's copy does not propagate to the other.

Reference: [Manage Your Metastore](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-metastore)

## Business Semantics — Governed Metric Views

Unity Catalog Business Semantics lets you define a business metric once, as a versioned UC object called a **metric view**, and query it at any grouping or filter without locking in aggregations at creation time — the query engine computes the correct result on the fly. Metric views integrate with Genie Spaces, AI/BI dashboards, and external BI tools, and carry **agent metadata** (synonyms, display names, format specs) that improves natural-language query accuracy for Genie.

```sql
CREATE OR REPLACE VIEW catalog.schema.orders_kpis WITH METRICS LANGUAGE YAML AS$$
  version: 1.1
  source: samples.tpch.orders
  fields:
    - name: Order Month
      expr: DATE_TRUNC('MONTH', o_orderdate)
  measures:
    - name: Total Revenue
      expr: SUM(o_totalprice)
      synonyms: ['revenue', 'total sales']
      format:
        type: currency
        currency_code: USD
$$

-- Query with MEASURE()
SELECT `Order Month`, MEASURE(`Total Revenue`)
FROM catalog.schema.orders_kpis
GROUP BY ALL;
```

### Auth model

Metric views use the standard UC privilege hierarchy — `SELECT` on the view for query access, ownership transfer to a group for collaborative editing. `SELECT` on the metric view does not itself grant `SELECT` on the underlying source tables: source access is checked at the metric view owner's identity (definer security), not the caller's — so a metric view can expose a governed aggregate without granting broad table access to every consumer.

### Materialization and per-user policies are mutually exclusive

Metric views support optional materialization (pre-computed aggregations) for dashboard performance. Row filters, column masks, and ABAC policies on the source tables (or the metric view itself) block materialization by design — pre-computed results would bypass per-user access controls evaluated at query time. Apply RLS/CLM/ABAC to base tables as usual; just plan whether a given metric view needs materialization or per-user filtering, since a single view can't have both.

### Gotchas

- **`current_user()` / `is_member()` in a metric view expression** also blocks materialization for the same reason — move identity-dependent logic to the source table's row filter instead.
- **No direct joins to other tables at query time** — wrap the metric view in a CTE first.
- **Materialized metric views cannot transfer group ownership** — plan editor access before enabling materialization if collaborative editing matters.

Reference: [Business Semantics](https://docs.databricks.com/aws/en/business-semantics/)

## Best Practices

### Identity and Group Design
- Grant to groups, never to individual users
- Use account-level groups for cross-workspace consistency; prefer account-level SCIM provisioning as the primary path and avoid running workspace-level SCIM in parallel once account-level SCIM is active, since both active together can produce duplicate groups and inconsistent row-filter evaluation
- Create a standard group taxonomy: `<catalog>_readers`, `<catalog>_writers`, `pii_readers`, `data_stewards`

### Managed vs External Tables

Default to **managed tables**. They are fully governed by UC: lifecycle, location, and access control are all owned by the metastore.

Use **external tables** only when the underlying storage must be shared with non-Databricks systems (e.g., a Spark cluster outside of Databricks, or a partner reading the same S3 prefix directly). When you do use external tables:

- Do not register the same external location across multiple metastores. If two metastores point to the same location, UC governance applies only to the metastore that manages the external table — the other metastore has unmediated access to the storage.
- Drop of an external table does NOT delete the underlying data. Ensure this is intentional; orphaned external data is a common source of ungoverned copies.
- For raw-data landing zones, prefer external volumes (finer-grained, FUSE-mountable, individually governed) over granting broad access to an external location.

| | Managed | External |
|---|---|---|
| Location managed by | Unity Catalog | You |
| Drop deletes data | Yes | No |
| Cross-metastore risk | None | High if same location registered in multiple metastores |
| Recommended default | **Yes** | Only when storage must be shared with non-Databricks systems |

### Catalog Design
- Use catalogs as environment boundaries: prod, staging, dev, sandbox
- Never run AI tools against prod with write permissions without approval workflow
- Don't use `main` catalog for production

### Compute Policy Enforcement

UC features (row filters, column masks, ABAC, data lineage) require compute in **Standard** or **Dedicated** access mode. Legacy no-isolation clusters bypass UC enforcement.

Enforce access mode via compute policies so users cannot create non-compliant clusters:

```json
{
  "spark_conf.spark.databricks.cluster.profile": {
    "type": "allowlist",
    "values": ["serverlessWorker", "singleUser"],
    "hidden": true
  },
  "data_security_mode": {
    "type": "allowlist",
    "values": ["SINGLE_USER", "USER_ISOLATION"],
    "hidden": true
  }
}
```

Attach this policy to user groups that should not be able to create legacy compute. Serverless SQL warehouses always run in Standard mode — no policy needed for warehouse-only users.

### MCP and AI Agent Governance
- One SP per capability boundary — read-only agent and write agent must have different SPs
- `USE CONNECTION` is the on/off switch for external service access
- OBO for user-facing calls; M2M for background tasks
- Application WHERE clauses are not governance — they are bypassed if someone queries the table directly, an agent uses a different code path, or a BI tool generates its own SQL

### Common Anti-Patterns

| Anti-Pattern | Risk | Correct Approach |
|---|---|---|
| `GRANT ALL PRIVILEGES ON CATALOG` | Admin access to everything | Grant specific privileges on specific objects |
| Application-level WHERE clauses | Bypassed by direct SQL access | Use UC row filters |
| Shared SP for all services | Lateral movement on compromise | One SP per capability boundary |
| `GRANT ... TO account users` | Everyone in the account gets access | Use named groups |
| Credentials in agent code | Exfiltration risk | Use UC Connections or Databricks Secrets |
| Registering an external table in more than one metastore | Schema drift between metastores | Use Delta Sharing / OpenSharing for cross-metastore access |
| Running workspace-level SCIM alongside account-level SCIM | Duplicate groups, inconsistent row-filter evaluation | Migrate fully to account-level SCIM, then disable workspace-level sync |

---

## Related Databricks Documentation

- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html)
- [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- [Row Filters & Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)
- [ABAC Tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)
- [Data Classification](https://docs.databricks.com/aws/en/data-governance/unity-catalog/data-classification)
- [Governed Tags](https://docs.databricks.com/aws/en/admin/governed-tags/)
- [UC Privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/index.html)
- [Manage Your Metastore](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-metastore)
- [Unity Catalog Best Practices](https://docs.databricks.com/aws/en/data-governance/unity-catalog/best-practices)
