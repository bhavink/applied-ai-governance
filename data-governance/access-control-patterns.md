# Fine-Grained Access Control Patterns

> Prescriptive patterns for enforcing row- and column-level access in Unity Catalog, with
> particular attention to **federated identity**, where external users authenticate through
> their own IdP and reach Databricks via token exchange. The central tension is covered in
> section 3: when access is via a service principal, `current_user()` is the SP, not the
> human, so individual-identity filters do not fire.

## 1. Data model patterns for access control

Access control effectiveness depends on how the data is modeled. The right pattern depends
on the granularity of control required and the identity model in use.

| Pattern | What it is | Best for | Data model requirement |
|---|---|---|---|
| Team / region-level | Rows carry a territory/team column; access by group membership | Regional teams, channel partners, geographic compliance | A `region` / `territory` / `team` column on every governed table |
| Individual-level | Rows tied to a specific user; only the owner sees them | "My accounts" views, patient-provider assignments, portfolios | An `owner_email` / `assigned_to` column mapped to an authenticated identity |
| Hierarchical | Managers see reports' data via an org-chart lookup | Management dashboards, approval workflows | A separate hierarchy table the filter JOINs against (query-time cost) |
| Attribute-based (ABAC) | Access combines role + department + clearance + sensitivity | Regulated industries, multi-dimensional rules | Governance columns on tables plus subject-attribute lookups |

Individual-level filtering has a critical caveat: it breaks when the authenticated identity
is a service principal (section 3).

## 2. Unity Catalog capabilities

### 2.1 Row filters

A row filter applies a SQL UDF to every query; only rows where it returns `TRUE` are visible.

```sql
CREATE OR REPLACE FUNCTION catalog.schema.region_filter(region_col STRING)
  RETURNS BOOLEAN
  RETURN (
    CASE
      WHEN is_account_group_member('executives') THEN TRUE
      WHEN is_account_group_member('sales-west') THEN region_col = 'WEST'
      WHEN is_account_group_member('sales-east') THEN region_col = 'EAST'
      ELSE FALSE
    END
  );

ALTER TABLE catalog.schema.sales_pipeline
  SET ROW FILTER catalog.schema.region_filter ON (region);

-- remove
ALTER TABLE catalog.schema.sales_pipeline DROP ROW FILTER;
```

Key rules: one row filter per table; parameters map positionally to the `ON (columns)` list;
runs on every query, so keep functions simple and deterministic; requires Unity Catalog and
a recent Databricks Runtime.

### 2.2 Column masks

A column mask replaces values dynamically based on the caller's identity.

```sql
CREATE OR REPLACE FUNCTION catalog.schema.mask_margin(margin_val DOUBLE)
  RETURNS DOUBLE
  RETURN (
    CASE
      WHEN is_account_group_member('finance') THEN margin_val
      WHEN is_account_group_member('executives') THEN margin_val
      ELSE -1.0  -- sentinel indicating masked
    END
  );

ALTER TABLE catalog.schema.sales_pipeline
  ALTER COLUMN margin SET MASK catalog.schema.mask_margin;
```

A mask can use other columns for context via `USING COLUMNS`:

```sql
CREATE OR REPLACE FUNCTION catalog.schema.mask_amount(amount_val DOUBLE, region_val STRING)
  RETURNS DOUBLE
  RETURN (
    CASE
      WHEN is_account_group_member('executives') THEN amount_val
      WHEN is_account_group_member('sales-west') AND region_val = 'WEST' THEN amount_val
      ELSE 0.0
    END
  );

ALTER TABLE catalog.schema.sales_pipeline
  ALTER COLUMN amount SET MASK catalog.schema.mask_amount USING COLUMNS (region);
```

The mask's first parameter and return type must match the column's data type.

### 2.3 Identity functions

| Function | Returns for a user | Returns for an SP | Recommended |
|---|---|---|---|
| `current_user()` | email | SP UUID | Legacy |
| `session_user()` | email | SP UUID | Yes (SQL standard) |
| `is_member('group')` | workspace-local group check | same | Prefer the account version |
| `is_account_group_member('group')` | account-level group check | same | Yes |

For service principals, both `current_user()` and `session_user()` return the SP's
application id (UUID), not a human name or the federated user's email.

### 2.4 GRANT / REVOKE

```sql
GRANT SELECT ON TABLE catalog.schema.sales_pipeline TO `sp-west-sales`;
GRANT EXECUTE ON FUNCTION catalog.schema.region_filter TO `sp-west-sales`;
GRANT USE CONNECTION ON CONNECTION external_api_conn TO `sp-admin`;
GRANT USE SCHEMA ON SCHEMA catalog.schema TO `sp-west-sales`;
GRANT USE CATALOG ON CATALOG catalog TO `sp-west-sales`;
```

### 2.5 ABAC via governed tags

The newer model applies policies centrally through governed tags: define tags at the account
level (for example `sensitivity: [public, internal, confidential, restricted]`), tag tables
and columns, create policy UDFs that reference tag values, and bind policies to tags so any
tagged object inherits the policy. One policy then covers all tables with a given tag, and
new tables inherit it when tagged. Limitations: requires a recent runtime or serverless,
cannot apply to views, and caps the number of column conditions in a match clause.

### 2.6 Key limitations

| Limitation | Impact |
|---|---|
| One row filter per table | Cannot compose multiple independent filters |
| Views cannot carry filters/masks | Filter at the base table |
| `current_user()` returns SP UUID | Individual-level filtering fails for federated SP access |
| Group checks cost on hot paths | Keep group checks out of per-row logic where possible |
| No cross-table filter composition | Each table's filter is independent |
| Time travel disabled on filtered tables | Cannot query historical snapshots |

## 3. The service principal identity gap

This is the central tension in federated access control.

### 3.1 The problem

```
External user (user@partner.example)
    -> external IdP login -> IdP JWT
    -> token exchange -> Databricks token (SP: sp-west-sales)
    -> SELECT * FROM sales_pipeline

Inside Databricks:
    session_user()  ->  SP UUID
    current_user()  ->  SP UUID
    Row filter: WHERE owner_email = current_user()  ->  no rows match
```

The human's email is not available inside filter functions when access is via a service
principal. This is by design: the SP is the authenticated principal.

### 3.2 What works and what does not

| Access pattern | Works with SP exchange? | Why |
|---|---|---|
| `is_account_group_member('sales-west')` | Yes | The SP can be a member of Databricks groups |
| `session_user() = 'user@partner.example'` | No | Returns the SP UUID, not the federated email |
| `owner_email = current_user()` | No | Same, returns the SP UUID |
| App-layer parameter passing | Yes (app-enforced) | The app sends user context as query parameters |

### 3.3 Workaround strategies

**Strategy A, group-based filtering (recommended).** Map external users to Databricks groups
via the SP; the SP belongs to the groups matching the user's role. The row filter uses
`is_account_group_member()`, not individual identity. Enforced by Unity Catalog, native for
SPs, auditable, no app-layer trust required. Granularity is limited to group boundaries
(team/region), not the individual. Use it for territory, role, or department filtering.

**Strategy B, application-enforced parameter passing.** The app layer adds a user-specific
WHERE clause before executing as the SP.

```python
external_email = get_federated_identity()   # from the verified IdP JWT
# parameterize; never string-concat untrusted input
result = execute_as_sp(
    "SELECT * FROM sales_pipeline WHERE account_owner_email = :email",
    {"email": external_email},
)
```

Gives individual granularity with any identity model, but governance is app-enforced, not
platform-enforced; a misconfigured app can bypass it, and it does not appear as a policy in
UC audit. Use only where you accept the app as a trust boundary, and always parameterize.

**Strategy C, mapping table + EXISTS.** A governance-maintained table links the acting
principal to its authorized scope; the filter joins against it.

```sql
CREATE TABLE catalog.schema.user_access_map (
  external_email     STRING,
  sp_application_id  STRING,
  authorized_region  STRING,
  authorized_accounts ARRAY<STRING>
);

CREATE OR REPLACE FUNCTION catalog.schema.mapped_filter(region_col STRING, account_id_col STRING)
  RETURNS BOOLEAN
  RETURN EXISTS (
    SELECT 1 FROM catalog.schema.user_access_map m
    WHERE m.sp_application_id = session_user()
      AND (m.authorized_region = region_col
           OR array_contains(m.authorized_accounts, account_id_col))
  );
```

Fine-grained, platform-enforced, auditable, but the filter JOINs on every query (cost) and
the mapping is per-SP unless you run a 1:1 SP-per-user model, which is impractical at scale.

**Strategy D, hybrid.** Unity Catalog row filters (group-based) for coarse access, app layer
for fine-grained column projection or value masking. Platform does the heavy lifting; the
split enforcement is harder to audit holistically.

### 3.4 Decision framework

```
Do all users in the same role see the same rows?
  |
  |-- YES -> Strategy A (group-based). Simplest, most secure, best-performing.
  |
  |-- NO  -> Does the user need to see only "their" records?
             |-- YES, platform enforcement required -> Strategy C (mapping table)
             |-- YES, app-layer enforcement acceptable -> Strategy B (parameter passing)
             |-- MIXED -> Strategy D (hybrid)
```

## 4. Design principles

### 4.1 The governance column pattern

Add explicit columns whose sole purpose is to support access policies (for example `region`,
`sensitivity_level`, `data_owner_email`, `department`). Make them NOT NULL with constrained
values, populate them at ingestion time rather than retroactively, and treat them as schema
contracts, as critical as primary keys.

### 4.2 Group-based vs individual-based

| Signal | Group-based | Individual-based |
|---|---|---|
| Users in same role see same data | Yes | Overkill |
| Federated access via SPs | Yes (native) | Requires workarounds |
| "My accounts" / "my patients" requirement | Insufficient | Required |
| Performance sensitivity | Better (simple boolean) | Worse (JOIN or app logic) |

### 4.3 Column masking vs row filtering

Row filter when some users should not see certain rows at all. Column mask when all users
see the row but some columns are redacted (PII partial display, financial figures for
finance only). For "right to be forgotten," a row filter excludes and a mask redacts.

### 4.4 Denormalization for governance

A row filter on a fact table cannot easily reference another table's column without a JOIN
inside the filter, which is a performance anti-pattern. For tables that will carry row
filters, prefer denormalizing the governance columns (`region`, `owner_email`) onto the fact
table so the filter references only local columns. Storage and ETL cost rise; filter
performance improves markedly and the access logic is self-contained per table.

## 5. Patterns by vertical

The same primitives (group-based row filters plus column masks) express access tiers across
industries. Representative tiers:

- **Healthcare (HIPAA)**: treating provider sees assigned patients with full clinical data;
  billing sees all patients in a facility, billing columns only; admin sees aggregates, no
  PHI; external auditor sees de-identified samples.
- **Financial services**: branch advisor sees own clients; branch manager sees the branch;
  regional director sees aggregates, no PII; compliance sees all; account numbers masked to
  the last four for non-privileged roles.
- **Retail / CPG**: store manager sees their store; district and regional roles see wider
  scopes; franchise and vendor partners (federated) see revenue and sell-through but not cost
  or margin.
- **SaaS multi-tenant**: `tenant_id` is a non-nullable governance column on every table;
  `tenant_isolation_filter` gates by tenant group; premium columns are masked for lower tiers.

Channel-partner / reseller federation is the pattern most relevant to external-app access:

| Role | IdP group | Databricks SP | Row access | Column access |
|---|---|---|---|---|
| Territory rep (west) | sales-west | sp-west-sales | WEST region | no margin |
| Territory rep (east) | sales-east | sp-east-sales | EAST region | no margin |
| Partner manager | managers | sp-manager | all regions | no margin |
| Partner exec | executives | sp-executive | all regions | full |
| External auditor | finance | sp-finance | all regions | full (incl. margin) |
| Platform admin | admin | sp-admin | all regions + audit | full + UC connections |

```sql
CREATE OR REPLACE FUNCTION catalog.schema.region_filter(region_col STRING)
  RETURNS BOOLEAN
  RETURN (
    CASE
      WHEN is_account_group_member('executives') THEN TRUE
      WHEN is_account_group_member('finance') THEN TRUE
      WHEN is_account_group_member('managers') THEN TRUE
      WHEN is_account_group_member('admin') THEN TRUE
      WHEN is_account_group_member('sales-west') THEN region_col = 'WEST'
      WHEN is_account_group_member('sales-east') THEN region_col = 'EAST'
      ELSE FALSE
    END
  );

CREATE OR REPLACE FUNCTION catalog.schema.mask_margin(margin_val DOUBLE)
  RETURNS DOUBLE
  RETURN (
    CASE
      WHEN is_account_group_member('finance') THEN margin_val
      WHEN is_account_group_member('executives') THEN margin_val
      ELSE -1.0
    END
  );

ALTER TABLE catalog.schema.sales_pipeline SET ROW FILTER catalog.schema.region_filter ON (region);
ALTER TABLE catalog.schema.sales_pipeline ALTER COLUMN margin SET MASK catalog.schema.mask_margin;
```

## 6. Trade-offs

| Pattern | Granularity | Complexity | Query perf | Works with SPs? | Platform enforced? |
|---|---|---|---|---|---|
| Group + `is_account_group_member()` | team / region | low | good | yes | yes |
| `current_user()` / `session_user()` | individual | low | good | no (SP UUID) | yes |
| App-layer parameter passing | individual | medium | good | yes (app-enforced) | no |
| Mapping table + EXISTS | individual | high | moderate (JOIN) | partial (per-SP) | yes |
| ABAC via governed tags | flexible | high setup | moderate | yes | yes |
| Dynamic views | flexible | medium | good | yes | yes |

Failure modes worth remembering: group-based cannot distinguish individuals in the same
group; `current_user()` matches nothing for federated SP access; app parameter passing can be
bypassed if misconfigured; mapping tables go stale and cost JOINs; ABAC tags need a recent
runtime and risk tag sprawl; dynamic views are read-only.

## 7. UDF best practices for filter/mask functions

Do: simple `CASE` and boolean expressions; deterministic logic; SQL UDFs over Python;
reference only columns from the target table; test on 1M+ rows before deploying. Do not: call
external APIs from a filter; use heavy subqueries/JOINs (the mapping-table pattern is the
accepted exception); use heavy regex on large text; nest UDFs; use non-deterministic logic
that breaks caching. Rough performance order, fastest first: group membership check, simple
column comparison, small `CASE`, EXISTS against a small lookup, EXISTS against a large mapping
table, Python UDF (much slower), external API call (never).

## 8. Implementation checklist

- **Data modeling**: identify governance columns per table; denormalize them onto fact
  tables; add NOT NULL and CHECK constraints; populate at ingestion; document which value
  maps to who.
- **Identity**: decide whether individual-level filtering is truly required (if not, use
  groups only); map external IdP groups to Databricks groups; assign SPs to groups; verify
  `is_account_group_member()` per SP; document the chain External user, IdP group, SP, DB
  group, row filter.
- **Deployment**: create filter/mask functions in a dedicated governance schema; GRANT
  EXECUTE to every SP that queries filtered tables; apply filters and masks; test each role
  or SP for correct visibility; verify production-scale performance.
- **Audit**: enable Unity Catalog audit logging; ensure the SP identity is traceable to the
  external user (see the audit correlation guidance in the identity and observability
  pillars); document what is platform-enforced vs app-enforced; schedule periodic access
  reviews.

## Related

- [Identity: Authorization](../identity/authorization.md), the token patterns and UC enforcement model
- [Identity: Production Federation Guide](../identity/federation-production.md), how the acting identity reaches UC
- [Identity: Per-User BYO-IdP Federation](../identity/byoidp-peruser-federation.md), the per-user path where `current_user()` is the human
- [Observability: Audit Reference](../observability/audit-reference.md), tying an SP-executed query back to the human

## Public References

- [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/row-and-column-filters)
- [ABAC with governed tags](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac)
- [is_account_group_member()](https://docs.databricks.com/aws/en/sql/language-manual/functions/is_account_group_member)
- [session_user()](https://docs.databricks.com/aws/en/sql/language-manual/functions/session_user)
- [Unity Catalog privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/privileges)
