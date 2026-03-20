# Genie Authorization Cookbook

> **Purpose**: Securing Genie Space deployments with Unity Catalog, from simple multi-team setups through enterprise-scale ABAC to multi-agent supervisor coordination.
>
> **Audience**: Field Engineers deploying Genie Spaces with UC governance at any scale.
>
> **Last updated**: 2026-03-12
>
> **Prerequisite**: Read [UC Policy Design Principles](../UC-POLICY-DESIGN-PRINCIPLES.md) for how `current_user()` and `is_member()` behave in Genie OBO contexts.

---

## 1. Security Fundamentals

### Genie Runs as the User (OBO)

When a user queries a Genie Space, the generated SQL executes as that user's identity. UC enforces row filters, column masks, ABAC policies, and privilege grants transparently.

### `current_user()` vs `is_member()` in Genie

| Function | Behavior in Genie OBO |
|---|---|
| `current_user()` | Returns the human email of the Genie user. Correct for per-user filtering. |
| `is_member('group')` | Evaluates the SQL execution identity, not always the calling user. May produce unexpected results. |

**Best practice**: Use `current_user()` + an allowlist table for group-based access. This works reliably across all OBO contexts.

```sql
-- Reliable pattern: allowlist table instead of is_member()
CREATE FUNCTION schema.team_filter(owner STRING, team STRING)
RETURNS BOOLEAN
RETURN CASE
  WHEN owner = current_user() THEN TRUE
  WHEN EXISTS (SELECT 1 FROM schema.role_assignments
    WHERE user_email = current_user() AND role = team) THEN TRUE
  ELSE FALSE END;
```

### Genie Space Access Control Layers

```
Layer 1: Genie Space membership (configured in UI)
Layer 2: UC catalog/schema/table grants (USE CATALOG, USE SCHEMA, SELECT)
Layer 3: Row filters (per-row access based on user identity)
Layer 4: Column masks (per-column value transformation)
```

---

## 2. Tier 1: Simple Multi-Team

**Scenario**: 3-5 teams (Sales, Marketing, Finance) share a single Genie Space. Each team sees only their authorized data. Executives see everything. 50-150 users.

### Data Model

Single catalog with team-specific schemas (`sales/`, `marketing/`, `finance/`, `shared/`). Each governed table includes governance columns (`owner_email`, `team`).

### UC Configuration

Three steps: (1) create groups and grant USE CATALOG / USE SCHEMA / SELECT per team, (2) create row filter functions using `is_member()` or `current_user()` with team/owner-based CASE logic, (3) create column mask functions for sensitive values (e.g., revenue amounts rounded for non-finance roles).

```sql
-- Row filter pattern: team-based with executive bypass
CREATE FUNCTION schema.filter_opps(owner STRING, team STRING)
RETURNS BOOLEAN
RETURN CASE
  WHEN is_member('executives') THEN TRUE
  WHEN is_member('sales-team') AND owner = current_user() THEN TRUE
  WHEN is_member('marketing-team') AND team = 'marketing' THEN TRUE
  ELSE FALSE END;
```

```sql
-- Column mask pattern: precision masking by role
CREATE FUNCTION schema.mask_revenue()
RETURNS DECIMAL(15,2)
RETURN CASE
  WHEN is_member('finance-team') THEN VALUE
  WHEN is_member('sales-team') THEN ROUND(VALUE, -3)
  ELSE NULL END;
```

### Genie Space Instructions

Provide role descriptions, common business term definitions (e.g., "pipeline" = sum of amounts before closed_won), and column/table references in the Genie Space instructions field.

### Test Matrix

| User | Query | Expected |
|---|---|---|
| alice (sales) | "My opportunities" | Only Alice's opportunities |
| bob (marketing) | "Campaign performance" | Only Bob's campaigns |
| carol (finance) | "Revenue for Q4" | Exact amounts |
| alice (sales) | "Total revenue Q4" | Rounded amounts (mask) |
| david (executive) | "All opportunities" | All teams, all data |

---

## 3. Tier 2: Enterprise Scale

**Scenario**: 5000+ employees, 50 countries, 20 departments. Hierarchical access (Employee > Manager > Director > Executive > HR Admin). Multi-dimensional security on department, region, role, and sensitivity.

### Data Model

HR analytics catalog with employee schemas (core_data, compensation, performance, attendance), organization schemas (departments, locations), analytics schemas (materialized views for headcount, attrition, diversity), and an audit schema.

**Key design**: Partition by `country` and `department` for performance. Include `data_sensitivity` column (`public`, `internal`, `confidential`) for ABAC filtering.

### ABAC Row Filter

The row filter function takes governance columns (email, manager, department, region, sensitivity, level) and uses a multi-branch CASE expression: HR admins see everything, executives see all except confidential, directors see their department's public/internal data, managers see direct reports and department public data, employees see only their own record. Special branches handle EMEA data residency and C-level data protection.

### PII Column Masks

Progressive salary disclosure: HR admins see exact values, executives see rounded to nearest 10K, directors see NULL (forced to aggregate views), employees see their own (row filter already limits to their record).

### Materialized Views for Performance

At 1000+ users, pre-aggregate common queries into materialized views (headcount by department/region, attrition rates). Grant these to all roles since they contain only aggregated data with no individual PII.

### Performance Targets

| User role | Query type | Target latency |
|---|---|---|
| Employee | Self-query | < 500ms |
| Manager | Team query | < 2s |
| Director | Department aggregate | < 3s (via materialized view) |
| Executive | Org-wide metric | < 5s (via materialized view) |

---

## 4. Tier 3: Multi-Agent Supervisor

**Scenario**: A supervisor agent routes queries to specialized Genie Spaces based on intent. Example: financial advisory platform with Portfolio Genie, Market Data Genie, and Compliance Genie.

### Architecture

```
Users (Clients, Advisors, Compliance Officers)
    |
    v
[Supervisor Agent]        <-- Intent classification (M2M, no user data)
    +-- Portfolio Genie   <-- OBO: client sees own, advisor sees assigned
    +-- Market Data Genie <-- OBO: public for all, premium for advisors
    +-- Compliance Genie  <-- OBO: compliance officers only
```

### Auth Strategy

The supervisor uses hybrid auth: M2M for intent classification (no user data needed), OBO for Genie routing (forwards user token so UC enforces per-user access), M2M for compliance logging (SP writes to audit table).

### Catalog Separation

Separate catalogs per domain for clear governance boundaries: `portfolio_catalog`, `market_catalog`, `compliance_catalog`.

### Per-Domain Row Filters

Each domain uses a CASE-based row filter: Portfolio uses hierarchical client > advisor > compliance. Market data uses tiered access (premium vs public). Compliance restricts to compliance officers only.

### Test Matrix

| User | Query | Routing | Expected |
|---|---|---|---|
| Client | "My portfolio balance" | Portfolio Genie | Own portfolio only |
| Advisor | "Show John's allocation" | Portfolio Genie | Assigned client data |
| Client | "Apple stock price?" | Market Data Genie | Public data only |
| Compliance | "Audit client X trades" | Compliance Genie | All trade history |
| Client | "Show all client trades" | Compliance Genie | Access denied |

---

## 5. Performance at Scale

**Partitioning**: Partition by the most common filter dimensions. Z-ORDER by columns used in filter function parameters.

**Materialized views**: Pre-aggregate for any query pattern that directors, executives, or large user groups commonly run (headcount, attrition, revenue aggregates, rating distributions).

**Result caching**: Enable at the warehouse level.

**Row filter simplicity**: Avoid subqueries (use allowlist tables with EXISTS instead of IN). Avoid complex string operations. Avoid calling other UDFs from within a row filter.

---

## 6. Monitoring and Audit

Track daily active users by team from `system.access.audit` filtering on `action_name = 'commandSubmit'`. Monitor permission denied spikes (status_code 403, threshold > 10 failures per user per day). Track compute hours by date for cost attribution.

For comprehensive Genie monitoring, see [audit-logging/genie-aibi/](../audit-logging/genie-aibi/).

---

## 7. Common Issues and Solutions

| Issue | Diagnosis | Fix |
|---|---|---|
| User sees 0 rows | Check group membership, row filter logic (`SHOW CREATE FUNCTION`), SELECT grants | Fix grants or filter CASE logic |
| User sees too much data | Verify filter is applied (`DESCRIBE TABLE EXTENDED`), test filter function with specific user, check for missing `ELSE FALSE` | Add missing branch or apply filter |
| Performance degraded | Check partitioning (`DESCRIBE DETAIL`), run OPTIMIZE, check for materialized views | Add materialized views, simplify filter |
| `is_member()` wrong result | Evaluates execution identity, not calling user | Replace with allowlist table + `current_user()` |
| Genie generates wrong SQL | Incomplete instructions | Add column names, business term definitions, role-specific query examples |

---

## Related Documents

- [UC Policy Design Principles](../UC-POLICY-DESIGN-PRINCIPLES.md) - `current_user()` vs `is_member()` across all execution contexts
- [Identity and Auth Reference](identity-and-auth-reference.md) - Auth patterns, token flows, scope reference
- [Authorization Flows](authorization-flows.md) - UC four-layer access control diagrams
- [audit-logging/genie-aibi/](../audit-logging/genie-aibi/) - Genie monitoring and analytics suite
- Databricks docs: [Genie Space](https://docs.databricks.com/aws/en/genie/), [Row Filters](https://docs.databricks.com/en/data-governance/unity-catalog/row-and-column-filters.html), [ABAC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac)
