# Federation Personas and Use-Case Patterns

> **What this is**: a reusable role taxonomy for external-user federation. It shows how a
> handful of external roles map through IdP groups to role service principals to Databricks
> groups, and how Unity Catalog then enforces per-role row and column access. Use it to plan
> which roles you need before you configure any policy. The mechanics of the exchange itself
> live in [Production Federation](federation-production.md); this doc is about the roles and
> what each one should see.

## The scenario this generalizes

An organization runs Databricks as its data platform and has **external stakeholders**
(channel partners, external auditors, technology partners, contracted consultants) who need
governed access to specific data and tools. These users do not exist in the organization's
directory; they authenticate with their own IdP. Role-based federation maps many such users
onto a few role service principals, and Unity Catalog enforces what each role sees. The value
of a persona model is that it forces the access decisions to be explicit before any grant is
written.

## Role taxonomy

The pattern uses a small, ordered set of roles. Names are illustrative; the shape carries
across industries.

| Role | Who it represents | Data scope | Sensitive columns | External tools |
|---|---|---|---|---|
| Territory rep (per region) | Front-line partner rep for one territory | that region's rows only | masked | none |
| Manager | Cross-region partner manager | all regions | masked | none |
| Executive | Partner executive sponsor | all regions, full detail | masked | integration + market-data connections |
| Finance / auditor | External finance or audit partner | all regions | unmasked margins | none |
| Admin | Partner platform/IT admin | all regions | unmasked | connection + audit access |

The recurring principle: data scope widens up the hierarchy, but sensitive-column visibility
and external-tool access are granted by function (finance sees margins, admin and executive
reach external connections), not by seniority alone.

## The identity chain

Each role resolves through the same chain, and every link is a distinct control point:

```
External user
  -> IdP group (carried as a groups claim in the token)
  -> role service principal (selected by the exchange)
  -> Databricks group (the SP is a member)
  -> Unity Catalog row filter / column mask (fires on is_account_group_member)
```

The external user is never provisioned in Databricks. The token carries the user's group
membership as a claim; the app maps that to a role SP during the RFC 8693 exchange; the SP
belongs to a Databricks group; and the row filter keys off that group. The individual's
identity is preserved for attribution in application audit, not in `current_user()`, because
the acting principal is the SP.

## Multi-group resolution

A user can belong to several IdP groups. Resolve to the **highest-privilege** role by a fixed
hierarchy so the mapping is deterministic:

| IdP groups on the token | Resolved role | Rationale |
|---|---|---|
| `[sales-west]` | territory rep (west) | single group, direct map |
| `[sales-east, managers]` | manager | manager outranks regional rep |
| `[executive, finance]` | executive | executive outranks finance |
| `[admin, executive, finance]` | admin | admin is top of the hierarchy |

Define the hierarchy once (admin, executive, finance, manager, then the per-region reps) and
apply it wherever the role is derived from the token's group claim, so the front end, the
exchange broker, and the server all agree.

## Access matrix

Row access by role (regions are illustrative):

| Role | West | East | Central | All |
|---|---|---|---|---|
| Territory rep (west) | Yes | No | No | No |
| Territory rep (east) | No | Yes | No | No |
| Manager | Yes | Yes | Yes | Yes |
| Executive | Yes | Yes | Yes | Yes |
| Finance / auditor | Yes | Yes | Yes | Yes |
| Admin | Yes | Yes | Yes | Yes |

Column masking and external access by role:

| Role | Margin column | Customer PII | External connections | Audit read |
|---|---|---|---|---|
| Territory rep | masked | masked | no | no |
| Manager | masked | visible | no | no |
| Executive | masked | visible | yes | yes |
| Finance / auditor | visible | masked | no | limited |
| Admin | visible | visible | yes | yes |

The point these matrices make in a demo or review: the same query run by two roles returns
different rows and different column values, enforced at the SQL engine, with no
application-side filtering. Genie generates the same SQL for everyone; the SP's group
membership decides what comes back, so natural-language access inherits the same governance.

## Governance column pattern

Every table needing row-level security carries a governance column whose values map to the
role boundary (for example `region`), so the filter is a simple group check plus a column
comparison.

```sql
CREATE TABLE sales.opportunities (
  id INT, deal_name STRING, amount DECIMAL,
  region STRING,               -- governance column: WEST, EAST, CENTRAL
  rep_email STRING, close_date DATE
);

CREATE FUNCTION sales.filter_by_region(region STRING)
RETURNS BOOLEAN
RETURN (
  is_account_group_member('admin')      OR
  is_account_group_member('executives') OR
  is_account_group_member('managers')   OR
  (is_account_group_member('west_sales') AND region = 'WEST') OR
  (is_account_group_member('east_sales') AND region = 'EAST')
);

ALTER TABLE sales.opportunities SET ROW FILTER sales.filter_by_region ON (region);
```

## The service principal identity gap

With role-based federation the acting principal is the SP, so `current_user()` returns the SP
application id, not the external user's email. Therefore `WHERE owner_email = current_user()`
does not work for individual-level filtering. Use group-based filtering with
`is_account_group_member()`, which supports SPs natively. If you need per-individual
enforcement in Unity Catalog rather than per-role, that is the per-user path, where the
external user is SCIM-synced and the exchange omits the SP so `current_user()` is the human.
See [Per-User BYO-IdP Federation](byoidp-peruser-federation.md) and the fuller treatment in
[Access Control Patterns](../data-governance/access-control-patterns.md).

## Industry mappings

The same taxonomy re-skins per vertical by choosing the governance column and one group per
boundary:

| Industry | Governance column(s) | Group design |
|---|---|---|
| Channel sales | `region` | one group per territory |
| Healthcare | `department_id`, `facility_id` | one group per department and facility |
| Financial services | `branch_code`, `jurisdiction` | one group per branch |
| SaaS multi-tenant | `tenant_id` | one group per tenant |
| Retail / franchise | `store_id`, `franchise_id` | one group per franchise |

## What this demonstrates

- External users are never provisioned in Databricks; they authenticate with their own IdP
  and tokens are exchanged server-side.
- Governance is native: row filters, column masks, and connection grants fire at the SQL
  engine, so AI tools (Genie, Vector Search, agents) inherit it because they run as the SP.
- Access is instantly reversible: one `GRANT` or `REVOKE USE CONNECTION` toggles external
  service access with no deploy.
- The IdP is swappable: moving from one OIDC provider to another changes the federation
  policy, not the SP architecture or the Databricks groups.

## Related

- [Production Federation Guide](federation-production.md), choosing per-user vs role-based and the exchange mechanics
- [Per-User BYO-IdP Federation](byoidp-peruser-federation.md), when `current_user()` must be the human
- [Federation](federation.md), the role-based exchange in depth
- [Access Control Patterns](../data-governance/access-control-patterns.md), row filters, masks, and the SP identity gap
- [Authorization](authorization.md), scopes and UC grants

## Public References

- [OAuth token federation](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation)
- [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/row-and-column-filters)
- [is_account_group_member()](https://docs.databricks.com/aws/en/sql/language-manual/functions/is_account_group_member)
