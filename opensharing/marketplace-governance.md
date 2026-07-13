<!--
  Synced from databricks-fieldkit on 2026-07-09
  Sources: sharing/marketplace-private-exchange.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/marketplace/private-exchange
  This file is auto-prepared and human-reviewed before publish.
-->

# Marketplace Governance — Curated Discovery on Top of OpenSharing

> **TL;DR**: Private Exchange is an invite-only Marketplace storefront built on OpenSharing. It adds a discovery and storefront layer on top of the underlying share/recipient mechanics — member organizations can browse what's on offer before requesting access, which plain OpenSharing doesn't surface on its own.

---

## When to use

| Scenario | Fit |
|---|---|
| A curated partner ecosystem where members should discover offerings before requesting them | Private Exchange |
| A direct 1:1 share where no listing or discovery step is needed | Standard OpenSharing (see [OpenSharing Governance](opensharing-governance.md)) |
| Public discoverability across all Databricks Marketplace users | Public Marketplace listing |

The discovery angle is the differentiator: members see what's available before requesting it, which is the piece OpenSharing alone doesn't provide.

---

## Requirements

- A Marketplace admin role on the provider side
- Members must be Databricks customers with a workspace attached to a Unity Catalog metastore
- The provider organization accepts the Databricks Marketplace Private Exchange terms

Member identity is expressed as a metastore sharing identifier: `<cloud>:<region>:<uuid>`.

---

## How listings work

Listings are either **public** or **private**; only private listings can be added to a private exchange (a public listing can be edited to private). Listings can additionally be **free** (instant access on request) or **approval-required** (the provider reviews each request before granting access).

---

## Governance

All standard OpenSharing governance applies to the shares underlying a Marketplace listing — the same ABAC, lineage, and audit trail described in [OpenSharing Governance](opensharing-governance.md) carries through. A Private Exchange listing is a discovery wrapper around a share; it does not change how the share itself is governed.

---

## Related

- [OpenSharing Governance](opensharing-governance.md) — the underlying sharing mechanism
- [Clean Rooms Governance](clean-rooms-governance.md) — the multi-party analytics alternative when raw data shouldn't be exposed to any party
