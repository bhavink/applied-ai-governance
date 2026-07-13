<!--
  Synced from databricks-fieldkit on 2026-07-09
  Sources: sharing/overview.md, sharing/opensharing.md, sharing/storage-network-gateway.md, sharing/sap-bdc-connector.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/data-sharing
    - https://docs.databricks.com/aws/en/opensharing/
  This file is auto-prepared and human-reviewed before publish.
-->

# OpenSharing Governance — Sharing Data Across Organizational Boundaries

> **TL;DR**: OpenSharing is Databricks' open-protocol, zero-copy data sharing platform for moving data across organizational and platform boundaries with governance intact. Two models: **D2D** (Databricks-to-Databricks — native Unity Catalog identity, no token management) and **D2O** (Databricks-to-Open — any platform, authenticated via bearer token or OIDC federation). It's the foundation Marketplace, Clean Rooms, and connectors like SAP Business Data Cloud are built on.

---

## The two sharing models

| Model | Recipient identity | Credential | Best for |
|---|---|---|---|
| **D2D** (Databricks-to-Databricks) | Native Unity Catalog identity via a sharing identifier | None — governed entirely through UC | Recipient runs a Unity Catalog-enabled Databricks workspace |
| **D2O** (Databricks-to-Open) | Bearer token or OIDC-federated JWT | Provider-issued credential file or IdP-issued token | Recipient is on any other platform — Spark, Pandas, Power BI, Tableau, Iceberg-compatible engines |

Recipients never need Unity Catalog, and a Databricks workspace is never required on the recipient side for D2O.

### Core objects

| Object | Meaning |
|---|---|
| **Provider** | The organization sharing data. Needs at least one Unity Catalog-enabled workspace. |
| **Recipient** | The organization receiving data — either D2D (UC) or D2O. |
| **Share** | A read-only, securable collection of tables, views, volumes, models, and notebooks. Cascade-delete revokes recipient access immediately. |

---

## Authentication and authorization

### D2D

Governed entirely through Unity Catalog identity — no separate credential to issue, rotate, or leak. The recipient's own metastore identity (a `<cloud>:<region>:<uuid>` sharing identifier) is what the provider grants access to.

### D2O — bearer token

The simplest path for recipients that can't do OIDC: the provider generates a long-lived, Databricks-issued bearer token and delivers a credential file out-of-band. Straightforward, but the token itself becomes a secret the recipient must protect and the provider must rotate.

### D2O — OIDC federation (recommended over bearer tokens)

OIDC federation replaces the long-lived bearer token with short-lived JWTs issued by the **recipient's own identity provider**. Databricks validates the JWT against a policy the provider configures — it never issues or stores the token itself.

Advantages over bearer tokens:
- Fine-grained access at the user, group, or application level
- MFA enforcement is delegated to the recipient's own IdP
- No shared long-lived credential to protect or rotate
- Token lifetime is controlled by the recipient's IdP, not Databricks

**Required policy fields** (illustrated with Entra ID; consult your IdP's documentation for exact equivalents):

| Field | Meaning | Entra ID example |
|---|---|---|
| Issuer URL | The token issuer (`iss` claim) | `https://login.microsoftonline.com/{tenantId}/v2.0` |
| Subject Claim | JWT field identifying the accessor | `oid` (single user) or `groups` (group) for U2M; `azp` for M2M |
| Subject | The specific ID being granted access | User Object ID, Group Object ID, or Application client ID |
| Audience | The token's intended recipient | Fixed multi-tenant app ID for U2M flows; the resource's own client ID for M2M |

There are three federation flows, each suited to a different recipient shape:

- **U2M (user-to-machine)** — a human using a BI tool such as Power BI or Tableau signs into their own IdP; the resulting JWT authorizes the session. Requires a one-time tenant-admin consent step in Entra ID before first use.
- **M2M (machine-to-machine)** — a service authenticates via OAuth Client Credentials, with its own registered application and client secret. No human in the loop.
- **Iceberg REST Catalog clients** — Iceberg-compatible engines (Snowflake, OSS Spark, and similar) can authenticate to shared data via OIDC instead of a bearer token, extending the same federation model to the Iceberg interoperability path described below.

### ABAC, row filters, and column masks on shared objects

Row filters and column masks applied **directly** to a table are evaluated per-recipient when the table is shared through a dynamic view — this is the supported pattern for governed sharing of filtered data. When building a share that needs row- or column-level policy, wrap the underlying table in a dynamic view and share the view rather than the base table.

Attribute-Based Access Control for shares (policy applied at the share/recipient level, distinct from table-level ABAC) is in Beta.

---

## Network security

### Per-recipient IP allowlisting

Providers can scope a D2O recipient's access to a fixed set of IPv4 addresses or CIDR ranges (up to 100 per recipient, allow-only). This covers the REST API, activation URL, and credential file download paths.

### SecureConnect

For providers sharing from firewalled or private-endpoint-protected storage, SecureConnect (Public Preview) removes the need to maintain a per-recipient IP allowlist. Databricks routes recipient requests through a managed proxy instead of requiring the provider to enumerate every recipient's network.

- **Recipients on serverless compute** need no firewall configuration at all — traffic is routed internally.
- **Recipients on classic/open compute** still allowlist a small, stable set of Databricks IP ranges rather than a per-recipient list.
- SecureConnect never initiates inbound connections into the recipient's network.
- Supported asset types: tables, views, foreign tables, materialized views, streaming tables. Volumes, notebooks, and AI models are shared through the standard D2D/D2O path instead.

---

## Worked example: SAP Business Data Cloud connector

The SAP Business Data Cloud (BDC) connector is a concrete instance of governed, bidirectional D2O sharing: data moves between Databricks and SAP BDC in either direction, zero-copy, secured with mutual TLS and OIDC. Table and column comments, primary keys, foreign keys, and governance tags sync into Unity Catalog alongside the data, so the semantic contract isn't lost in translation. Setup requires `CREATE PROVIDER` and `CREATE RECIPIENT` privileges on the Databricks side and a matching Third Party Connection on the SAP BDC side.

---

## Audit

All OpenSharing activity is captured in `system.access.audit`, joinable with the rest of your Unity Catalog audit trail:

```sql
-- Recent share reads
SELECT
  event_time, action_name, request_params.recipient_name,
  request_params.share_name, request_params.table_full_name
FROM system.access.audit
WHERE service_name = 'unityCatalog'
  AND action_name LIKE 'deltaSharing%'
  AND event_time > current_timestamp() - INTERVAL 7 DAYS;

-- Failed access attempts per recipient
SELECT request_params.recipient_name, response.error_message, COUNT(*) AS denials
FROM system.access.audit
WHERE action_name LIKE 'deltaSharing%'
  AND response.status_code >= 400
GROUP BY 1, 2 ORDER BY denials DESC;
```

---

## Related

- [Clean Rooms Governance](clean-rooms-governance.md) — multi-party analytics built on OpenSharing
- [Marketplace Governance](marketplace-governance.md) — the discovery layer on top of OpenSharing
- [Data Governance — Unity Catalog](../data-governance/uc-governance.md) — ABAC, row filters, and column masks referenced above
- [Federation](../identity/federation.md) — the RFC 8693 token-exchange pattern OIDC federation builds on
