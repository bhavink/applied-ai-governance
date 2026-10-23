# Fine-Grained Access Control Patterns

> Prescriptive patterns for enforcing row- and column-level access in Unity Catalog, with
> particular attention to **federated identity**, where external users authenticate through
> their own IdP and reach Databricks via token exchange. The central tension is covered in
> section 3: external callers share a service principal while an OAuth custom identity claim
> carries the immutable end-user subject into Unity Catalog policy evaluation.

## 1. Data model patterns for access control

Access control effectiveness depends on how the data is modeled. The right pattern depends
on the granularity of control required and the identity model in use.

| Pattern | What it is | Best for | Data model requirement |
|---|---|---|---|
| Team / region-level | Rows carry a territory/team column; access by group membership | Regional teams, channel partners, geographic compliance | A `region` / `territory` / `team` column on every governed table |
| Individual-level | Rows tied to a specific user; only the owner sees them | "My accounts" views, patient-provider assignments, portfolios | An `owner_email` / `assigned_to` column mapped to an authenticated identity |
| Hierarchical | Managers see reports' data via an org-chart lookup | Management dashboards, approval workflows | A separate hierarchy table the filter JOINs against (query-time cost) |
| Attribute-based (ABAC) | Access combines role + department + clearance + sensitivity | Regulated industries, multi-dimensional rules | Governance columns on tables plus subject-attribute lookups |

Individual-level filtering must use the identity function for the caller boundary: native
users use `current_user()`; external people use `current_oauth_custom_identity_claim()`.

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
| `current_user()` returns SP UUID | Expected for federation; use `current_oauth_custom_identity_claim()` for the external subject |
| Group checks cost on hot paths | Keep group checks out of per-row logic where possible |
| No cross-table filter composition | Each table's filter is independent |
| Time travel disabled on filtered tables | Cannot query historical snapshots |

## 3. External-user authorization

There is one supported pattern for external people without Databricks accounts:

```
External user -> external IdP -> validated identity -> Databricks OAuth token
              -> shared service principal + immutable custom identity claim
              -> Unity Catalog row filter -> governed entitlement table
```

`current_user()` and `session_user()` continue to return the shared service principal. That
is the workload identity and is expected. `current_oauth_custom_identity_claim()` returns the
external subject used for end-user authorization.

```sql
CREATE TABLE governance.identity.external_user_entitlements (
  external_subject STRING NOT NULL,
  account_id       STRING NOT NULL,
  enabled          BOOLEAN NOT NULL
);

CREATE OR REPLACE FUNCTION governance.identity.external_account_filter(account_id STRING)
RETURNS BOOLEAN
RETURN EXISTS (
  SELECT 1
  FROM governance.identity.external_user_entitlements entitlement
  WHERE entitlement.external_subject = current_oauth_custom_identity_claim()
    AND entitlement.account_id = account_id
    AND entitlement.enabled = TRUE
);

ALTER TABLE catalog.schema.sales_pipeline
SET ROW FILTER governance.identity.external_account_filter ON (account_id);
```

The claim must contain an opaque, immutable identifier, not email, roles, permissions, or
secrets. Missing claims and missing mappings fail closed. Never interpolate the claim into
SQL or use it as an identifier or regular expression.

Do not implement external-user authorization with role service principals, SP group
membership, application-supplied SQL predicates, or a hybrid app/UC policy. Those approaches
either collapse multiple humans into one authorization identity or move enforcement outside
Unity Catalog.

See [External-User Authorization](../identity/external-user-authorization.md) for platform
requirements, grants, audit correlation, and validation gates.

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

| Caller pattern | Policy identity | Complexity | Query perf | Platform enforced? |
|---|---|---|---|---|
| Native Databricks user | `current_user()` / `session_user()` | low | good | yes |
| External person | `current_oauth_custom_identity_claim()` + entitlement lookup | medium | moderate | yes |
| Non-interactive workload | Service principal UC grants | low | good | yes |

These rows describe identity boundaries, not competing implementation choices. For external
people, role-SP groups, application-supplied predicates, and hybrid enforcement are rejected
patterns because they do not provide one authoritative per-person policy in Unity Catalog.

## 7. UDF best practices for filter/mask functions

Do: simple `CASE` and boolean expressions; deterministic logic; SQL UDFs over Python;
reference only columns from the target table; test on 1M+ rows before deploying. Do not: call
external APIs from a filter; use heavy subqueries/JOINs (the external entitlement lookup is the
accepted exception); use heavy regex on large text; nest UDFs; use non-deterministic logic
that breaks caching. Rough performance order, fastest first: group membership check, simple
column comparison, small `CASE`, EXISTS against a small lookup, EXISTS against a large mapping
table, Python UDF (much slower), external API call (never).

## 8. Implementation checklist

- **Data modeling**: identify governance columns per table; denormalize them onto fact
  tables; add NOT NULL and CHECK constraints; populate at ingestion; document which value
  maps to who.
- **Identity**: classify the caller as native user, external person, or workload. For an
  external person, mint the immutable custom identity claim and verify
  `current_oauth_custom_identity_claim()` through the production token path.
- **Deployment**: create filter/mask functions in a dedicated governance schema; GRANT
  EXECUTE to every SP that queries filtered tables; apply filters and masks; test each role
  or SP for correct visibility; verify production-scale performance.
- **Audit**: enable Unity Catalog audit logging; ensure the SP identity is traceable to the
  external user (see the audit correlation guidance in the identity and observability
  pillars); document what is platform-enforced vs app-enforced; schedule periodic access
  reviews.

## Related

- [Identity: Authorization](../identity/authorization.md), the token patterns and UC enforcement model
- [Identity: External-User Authorization](../identity/external-user-authorization.md), the canonical external-person path
- [Identity: Per-User BYO-IdP Federation](../identity/byoidp-peruser-federation.md), the per-user path where `current_user()` is the human
- [Observability: Audit Reference](../observability/audit-reference.md), tying an SP-executed query back to the human

## Public References

- [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/row-and-column-filters)
- [ABAC with governed tags](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac)
- [is_account_group_member()](https://docs.databricks.com/aws/en/sql/language-manual/functions/is_account_group_member)
- [session_user()](https://docs.databricks.com/aws/en/sql/language-manual/functions/session_user)
- [current_oauth_custom_identity_claim()](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/current_oauth_custom_identity_claim)
- [Unity Catalog privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/privileges)
