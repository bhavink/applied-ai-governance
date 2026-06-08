<!--
  Synced from databricks-fieldkit on 2026-04-27
  Sources: governance/context-based-ingress.md, apps/_azure/context-based-policies.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/security/network/front-end/context-based-ingress
    - https://docs.databricks.com/aws/en/security/network/front-end/manage-ingress-policies
    - https://learn.microsoft.com/en-us/azure/databricks/security/network/
  This file is auto-prepared and human-reviewed before publish.
-->

# Network Controls — Ingress Governance for AI Workloads

> **TL;DR**: When AI agents and apps run on Databricks, ingress governance answers three questions in layers: *who* is calling, *from where*, and *which surface* (Workspace UI, API, Apps, Lakebase Compute). The primary control is **account-level context-based ingress** — one policy can govern multiple workspaces and combines identity × network source × access type. Per-cloud primitives (Private Link, Azure Firewall, NSG, Conditional Access) sit underneath as additional layers. AI workload owners should configure both: the account policy as the ceiling, the cloud primitives for refinement.

---

## Why Network Controls Matter for AI Governance

Agents and AI apps are high-value targets and often handle sensitive data through their tool calls. A complete AI governance posture combines:

| Layer | Question it answers | Where it lives |
|---|---|---|
| **Identity (auth)** | Who is the caller? | OAuth scopes, OBO/M2M tokens |
| **Authorization (data)** | What data can this identity see? | Unity Catalog grants, row filters, column masks |
| **Network (this doc)** | From where can this caller reach the workspace at all? | Account ingress policy + cloud primitives |

Without network ingress governance, an attacker holding a stolen token can call Databricks APIs from any IP. With it, the account policy can require humans to come from corporate IP ranges, allow service principals from cloud automation ranges, and deny entirely from unexpected geographies — all in one policy that applies to every workspace.

---

## Layered Model

```
Internet  ·  Corporate VPN  ·  Private Link  ·  Cloud peering
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│ 1. Front-end Private Link (network reachability) │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│ 2. Account-level context-based ingress policy    │
│    Identity × Network source × Access type       │
│    DENY beats ALLOW. Default deny when restricted │
└──────────────────────────────────────────────────┘
                          │  (must be allowed here)
                          ▼
┌──────────────────────────────────────────────────┐
│ 3. Workspace IP access lists (narrowing only)    │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│ 4. Domain firewall rules                         │
└──────────────────────────────────────────────────┘
                          │
                          ▼
[ Workspace UI · API · Apps · Lakebase Compute ]
```

**Order of evaluation matters.** The account policy is checked before workspace IP access lists. If the account policy denies, IP access lists never get a chance to allow — they can only narrow, not widen.

---

## Account-Level Context-Based Ingress

A single policy attaches to one or more workspaces. Each rule combines four dimensions.

### Rule grammar

| Dimension | Values |
|---|---|
| **Access type** | `Workspace UI` · `API` · `Apps` · `Lakebase Compute` |
| **Identity type** | `All users and service principals` · `All users` · `All service principals` · `Selected identities` |
| **Network source** | `All public IPs` · `Selected IPs` (CIDR list) |
| **Operator (Deny rules)** | `IN` (block matching) · `NOT IN` (block everything except matching) |

### Identity-type support per access type

| Access type | Supported identity types |
|---|---|
| `Workspace UI` | All four |
| `API` | All four |
| `Apps` | `All users and service principals` only |
| `Lakebase Compute` | `All users and service principals` only |

For `Apps` and `Lakebase Compute`, identity-level filtering happens in the application layer (OBO claims, UC grants, Postgres roles), not in the ingress policy.

### Enforcement modes

| Mode | Behavior |
|---|---|
| **Enforced for all products** | Violations blocked |
| **Dry run mode for all products** | Violations logged but allowed — safe rollout |

**Recommended rollout pattern**: author the policy → attach in dry-run → query `system.access.inbound_network` for `DRY_RUN_DENIAL` rows → fix false positives → flip to enforced.

### Audit table

All denials (enforced and dry-run) land in `system.access.inbound_network`.

```sql
-- Last 2 hours of inbound denials
SELECT *
FROM system.access.inbound_network
WHERE event_time >= CURRENT_TIMESTAMP() - INTERVAL 2 HOUR
ORDER BY event_time DESC;

-- Dry-run denials only — what enforced mode would block
SELECT request_type, identity, network_source, COUNT(*) AS denials
FROM system.access.inbound_network
WHERE action = 'DRY_RUN_DENIAL'
  AND event_time >= CURRENT_TIMESTAMP() - INTERVAL 7 DAYS
GROUP BY 1, 2, 3
ORDER BY denials DESC;
```

| Column | Captures |
|---|---|
| `event_time` | When the request hit the policy |
| `workspace_id` | Target workspace |
| `request_type` | UI · API · Apps · Lakebase |
| `identity` | User or service principal |
| `network_source` | Source IP / VNet / Private Link origin |
| `action` | `DENIED` or `DRY_RUN_DENIAL` |

Logs can lag several minutes — for live triage, check the request directly on the workspace API.

### Configure via Account Console

1. Account Console → **Previews** → enable **Context-based Ingress Control**
2. Account Console → **Security** → **Networking** → **Context-based ingress & egress control** → **Create new network policy**
3. Name the policy → **Ingress** tab → choose mode → add Allow/Deny rules
4. Account Console → **Workspaces** → select workspace → **Network Policy** → apply

Workspaces with no explicit policy use the default. Editing the default propagates to every unassigned workspace — pilot named policies first.

---

## Common Patterns

### "Corporate VPN only" for humans, anywhere for service principals

- **Allow** `Workspace UI` + `All users` + `Selected IPs (203.0.113.0/24)`
- **Allow** `API` + `All users` + `Selected IPs (203.0.113.0/24)`
- **Allow** `API` + `All service principals` + `All public IPs`
- Mode: **Restrict access based on request context**

### Block a known-bad range

- **Deny** `API` + `All users and service principals` + `Selected IPs (a.b.c.d/24)` + operator `IN`
- Deny rules override Allow — no need to remove existing allows.

### Apps reachable only from a partner's IP range

- **Allow** `Apps` + `All users and service principals` + `Selected IPs (partner_cidr)`
- For human-vs-SP separation, filter at the app layer (custom auth, OBO claims).

### Tighten safely with dry-run

- Add the new restrictive rule alongside existing allows
- Switch policy to **Dry run mode for all products**
- Wait 7 days, query `inbound_network` for `DRY_RUN_DENIAL`
- Whitelist legitimate denials, then flip to **Enforced**

---

## Per-Cloud Network Primitives

The account policy sits on top of cloud-native primitives. Configure both for defense in depth.

### Azure

| Primitive | Purpose |
|---|---|
| **Front-end Private Link** | Reach workspace only via private endpoint in your VNet |
| **Azure Firewall (FQDN allowlist)** | Egress filtering for hosted apps reaching external SaaS |
| **Network Security Groups** | IP-based outbound rules on Databricks subnets |
| **Entra Conditional Access** | Per-user MFA, device compliance, location-based session policies |

Typical pattern for hosted apps that need outbound calls (e.g., custom MCP servers calling external APIs):

```
Rule Collection: databricks-apps-egress (Allow)
Application Rules (FQDN-based):
  ├── *.salesforce.com
  ├── api.github.com
  ├── *.slack.com
  ├── *.googleapis.com
  └── login.microsoftonline.com
```

FQDN-based allowlists are more durable than IP-based rules when SaaS providers rotate addresses.

### AWS

| Primitive | Purpose |
|---|---|
| **Front-end PrivateLink** | Reach workspace only via VPC endpoint |
| **Security Groups + NACLs** | Subnet-level network controls |
| **Domain firewall rules** | FQDN allowlist for outbound traffic |

### GCP

| Primitive | Purpose |
|---|---|
| **Private Service Connect (PSC)** | Reach workspace only via PSC endpoint |
| **VPC Service Controls (VPC-SC)** | Service perimeters around UC and serverless |
| **Cloud Armor / Cloud NGFW** | Edge network filtering |

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| A multi-tenant agent platform | Account policy denying API ingress except from corporate ranges + cloud SP ranges |
| A Databricks App reachable from a partner network | Allow rule for `Apps` + `Selected IPs` matching the partner CIDR |
| A Lakebase-backed agent memory store | Allow rule for `Lakebase Compute` from app subnets only |
| Tightening an existing workspace | Add policy in dry-run; review `inbound_network` for 7 days; flip to enforced |
| Cross-region failover | Mirror the policy on the failover account or include both ranges in the same policy |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Relying solely on workspace IP access lists across many workspaces | Consolidate to one account-level policy; use IP access lists for workspace-specific narrowing only |
| IP-based egress allowlists for SaaS | FQDN-based rules in cloud firewall — durable when SaaS providers rotate IPs |
| Editing the default network policy as a first step | Create a named policy and attach to a single workspace first; default propagates broadly |
| Switching to "Restrict" mode without dry-run | Dry-run for at least 7 days; review `inbound_network` denials before flipping |

---

## Related

- [`identity/authorization.md`](../identity/authorization.md) — Identity types referenced by ingress rules (user vs SP)
- [`identity/oauth-scopes-reference.md`](../identity/oauth-scopes-reference.md) — Scope ceiling that pairs with network controls
- [`uc-governance.md`](uc-governance.md) — Data-layer governance, the layer below network ingress

---

## Public References

- [AWS — Context-based ingress control](https://docs.databricks.com/aws/en/security/network/front-end/context-based-ingress)
- [AWS — Manage context-based ingress policies](https://docs.databricks.com/aws/en/security/network/front-end/manage-ingress-policies)
- [Azure — Network security overview](https://learn.microsoft.com/en-us/azure/databricks/security/network/)
- [AWS — Manage IP access lists](https://docs.databricks.com/aws/en/security/network/front-end/ip-access-list)
- [System tables: `inbound_network`](https://docs.databricks.com/aws/en/admin/system-tables/) (account audit schema)
