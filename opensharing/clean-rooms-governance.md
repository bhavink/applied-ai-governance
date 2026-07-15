<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: sharing/clean-rooms.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/clean-rooms/
  This file is auto-prepared and human-reviewed before publish.
-->

# Clean Rooms Governance — Multi-Party Analytics Without Raw Data Exposure

> **TL;DR**: Clean Rooms combine OpenSharing with serverless compute inside a Databricks-managed, isolated environment where multiple parties can jointly analyze data without any party seeing another's raw rows. The default model is no-trust: every collaborator, including the creator, holds equal privileges, and code runs only once every party has approved it.

---

## When to use

| Scenario | Fit |
|---|---|
| Joint analytics across organizations where no party should see the other's raw data (fraud detection, attribution, joint research) | Clean Rooms |
| One side legitimately needs raw access to the other's data | Standard OpenSharing (see [OpenSharing Governance](opensharing-governance.md)) |
| A curated, discoverable catalog of shareable assets | [Marketplace Governance](marketplace-governance.md) |

---

## The no-trust model

Creating a clean room provisions three securable objects: a clean room object in the creator's Unity Catalog metastore, an isolated and ephemeral central clean room managed by Databricks, and a clean room object in each collaborator's metastore. Each party contributes tables, views, volumes, and notebooks **into** the central clean room — never directly to another participant.

Every collaborator holds equal privileges. There is no creator-admin distinction: a notebook only runs after **every** collaborating party has explicitly approved it, including the party that authored it. Running a notebook authored by another party counts as implicit approval of its code. Only the most recent version of a notebook is eligible to run, and the clean room events system table records exactly which version executed.

A clean room supports up to ten collaborators, reflecting the design intent of the no-trust model — every added party increases the mutual-approval surface. Once created, a clean room is locked to its initial participant set; if any collaborator deletes the clean room, all pending tasks become void for everyone.

### What collaborators can and cannot see

Collaborators can see: the clean room name, cloud and region, organization name, the sharing identifier, aliases of contributed tables/views/volumes, column names and types, read-only notebooks, read-only temporary output tables, and run history.

Collaborators cannot see: any row-level data contributed by another party. Column metadata is visible; the underlying values are not.

### Output tables

Approved notebook runs produce read-only, temporary output tables that land in each party's **own** Unity Catalog metastore. From that point on, they behave like any other UC table for the receiving party.

---

## Prerequisites

Setting up a clean room requires a workspace with serverless compute and Unity Catalog enabled, plus OpenSharing enabled on the metastore — the same underlying sharing mechanism a clean room uses to move contributed assets into the central environment.

## Supported Workloads

Notebooks are the primary execution method and go through the full multi-party approval flow described above. JAR workloads are also supported for teams that need to run compiled Scala/Java logic rather than notebook code.

---

## Packaged Clean Rooms — the provider-consumer exception

Packaged Clean Rooms depart from the equal-privilege, no-trust default by design: they use a provider-consumer model where the provider controls the environment and consumers do not hold equal privileges. This pattern fits scenarios like distributing a pre-built analytics package to multiple customers, where the provider's code and logic should not be alterable by consumers.

---

## Network controls

Serverless egress control lets a clean room creator restrict outbound network connections from the central clean room — blocking writes to unauthorized storage and calls to unapproved external services. The central clean room itself always runs inside an isolated, Databricks-managed serverless compute plane, separate from any collaborator's own infrastructure.

---

## Audit

Clean room actions are captured in the dedicated clean room events system table (detailed action-level metadata) and in `system.access.audit` under the `clean-room` service:

```sql
SELECT event_time, action_name, request_params, user_identity.email
FROM system.access.audit
WHERE service_name = 'clean-room'
  AND event_time > current_timestamp() - INTERVAL 7 DAYS
ORDER BY event_time DESC;
```

Permission changes within a metastore are captured separately under the `unityCatalog` service.

---

## Cloud Availability

The clean room creator chooses the cloud and region for the central clean room; collaborators can join from any cloud that supports the OpenSharing contribution path.

| Cloud | Creator | Collaborator |
|---|---|---|
| AWS | Yes | Yes |
| Azure | Yes | Yes |
| GCP | Yes | Yes |

GCP support was added as of Summer 2025, so all three major clouds now support the full creator/collaborator lifecycle.

---

## Operational Notes

| Situation | What to know |
|---|---|
| Naming a clean room | The name cannot be changed after creation and must be unique across every collaborator's metastore — choose it deliberately upfront |
| Communicating context to collaborators | Comments added to a clean room securable don't propagate to other parties' views of it — coordinate context out-of-band |
| Sharing tables from default storage | This path currently requires enabling a Beta feature ("OpenSharing for Default Storage – Expanded Access"); use external storage tables if you'd rather stay off Beta features |
| Scaling to many assets | Clean room securables are subject to account-level resource quotas — plan asset counts ahead of a large collaboration and engage your account team if you expect to scale significantly |
| Referencing the sharing identifier | The identifier is the full string (global metastore ID + workspace ID + user email) — use it in full from the UI rather than a partial value |
| Applying ABAC to contributed tables | Apply row filters, column masks, and tags to a table before contributing it to a clean room, and verify the policy behaves as expected on the underlying table first |

---

## Related

- [OpenSharing Governance](opensharing-governance.md) — the sharing mechanism clean rooms are built on
- [Marketplace Governance](marketplace-governance.md) — curated discovery layer
- [Data Governance — Unity Catalog](../data-governance/uc-governance.md) — ABAC considerations for tables before they're contributed to a clean room
