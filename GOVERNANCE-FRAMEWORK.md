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

Any AI governance architecture that answers these six questions at every layer, absorbing new AI capabilities without redesign, will outlast the tools it governs.

---

## Design Principles

### 0. Lead with the business need, not the technology

Technology is a means, not the end. Every pillar, presentation, and document in this repository must start with the business challenge it solves, not the Databricks feature that implements it.

The pattern:

1. **The need:** What does the business require? Plain-English analytics, knowledge retrieval, multi-agent orchestration, governed access for partners. Real, specific, relatable.
2. **The tension:** What makes this hard? Two identity worlds, external users without platform accounts, compliance across organizational boundaries.
3. **The platform:** Databricks resolves the tension. *Now* you name Genie, Vector Search, Agent Bricks, Unity Catalog, AI Gateway. The reader arrives at the technology naturally because the business need led them there.
4. **The how:** The rest of the content delivers the implementation.

A pillar that opens with "Unity Catalog row filters let you..." is doing it wrong. A pillar that opens with "Sales reps should only see their region's pipeline, partners should see aggregated metrics but never individual records..." is doing it right. The reader should feel the problem before they hear about the solution.

**The test:** If you removed every Databricks product name from the first two paragraphs, would the content still resonate with a business leader? If yes, the framing is right.

### 1. Govern at the data layer, not the application layer

Applications change. Data governance doesn't. If your access control lives in application code, every new AI tool requires new governance code. If it lives in the data platform, every new AI tool inherits governance automatically.

Row filters, column masks, and connection grants are enforced by the SQL engine. No application can bypass them. No new AI service needs to "integrate" with them: it just issues SQL and governance fires.

**The test:** Can you add a new AI tool to your stack tomorrow without writing a single line of governance code? If yes, you're governing at the right layer.

### 2. Identity is the invariant

Tools change. Protocols change. Identity is the one constant across every governance decision. Design everything around identity:

- **Human identity** propagates through OBO tokens: `current_user()` is the human's email at every layer
- **Role identity** maps to service principals via group membership: `is_member()` evaluates at the SQL engine
- **Service identity** authenticates via M2M credentials: background jobs, pipelines, audit writers

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

The most secure governance is invisible to the user. Row filters don't return errors; they return fewer rows. Column masks don't block queries; they return NULL for sensitive fields. The user never sees an "access denied" on data they shouldn't know exists.

Loud failures (HTTP 403, permission errors) are appropriate for capability boundaries: you can't call a tool you don't have access to. But within the data layer, silence is the correct behavior. A query that returns 0 rows is governance working, not a bug.

### 5. Audit everything, trust nothing

Platform audit captures what the system sees. Application audit captures what the user intended. Neither is complete alone:

- Platform audit records the SP identity but not the human behind a federated request
- Application audit records the human email but can be tampered with by a compromised app
- Only the correlation of both, joined on request_id and timestamp, gives the full chain of custody

Design for forensics, not just monitoring. The question isn't "what happened today" but "can you reconstruct exactly what happened 90 days ago for a specific user on a specific dataset?"

### 6. Govern connections, not just data

Traditional data governance asks: can this identity SELECT from this table? AI governance adds a new question: can this identity call this external service?

UC Connections are the governance primitive for external tool access. `GRANT USE CONNECTION` is the on/off switch. `REVOKE USE CONNECTION` is instant, requires no redeployment, and is audited. This is how you prevent the confused deputy, a pattern where a privileged service blindly executes requests from untrusted callers.

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

## Pillars This Repository Documents

The six questions above are answered across every layer of a Databricks deployment. This repository goes deep on the three pillars where identity and observability are established and where an agent runtime enforces them. The remaining concerns (the network perimeter, data-layer filtering, connection governance, and compliance-as-SQL) are enforced by Databricks platform features, and this repository cites the public documentation where they come up rather than restating them.

```
+------------------------------------------------------------------+
|                     Applied AI Governance                         |
+------------------------------------------------------------------+
|  Documented in depth here:                                        |
|                                                                   |
|  [1] Identity &      OBO (U2M), M2M, Federation. Three models,    |
|      Access Control  one governance plane. OAuth scopes enforce   |
|                      least privilege per token.                   |
|                                                                   |
|  [2] Observability   Platform audit + app audit + MLflow traces.  |
|      & Audit         Chain of custody: human -> tool -> SQL.      |
|                                                                   |
|  [3] Agent Runtime   Where identity and observability meet at     |
|      Harness         runtime: per-user tokens, policy verdicts,   |
|                      traces, and cost caps around tool calls.     |
|                                                                   |
|  Enforced by the platform (cited to Databricks docs):             |
|  network isolation, row filters and column masks, UC Connections, |
|  governance-as-SQL for compliance.                                |
+------------------------------------------------------------------+
```

### Pillar 1: Identity & Access Control

**Question:** Who is making this request, and what capabilities does their token grant?

Three identity models, one governance plane:

| Model | Token Source | `current_user()` | Best For |
|-------|-------------|-------------------|----------|
| **OBO (U2M)** | Apps proxy injects user's scoped token | Human email | Internal apps, interactive |
| **M2M** | SP client credentials | SP application ID | Background jobs, pipelines, audit |
| **Federation** | External IDP JWT exchanged for SP token | SP application ID | Partner portals, external users |

OAuth scopes enforce least privilege per token: `sql`, `genie`, `serving`, never `all-apis`. The scope is the maximum capability; UC grants are the actual authorization.

**Future-proof because:** Every new Databricks AI service supports OAuth tokens and UC identity. The three models cover all caller types (human-with-account, machine, human-without-account), so new services do not require new identity patterns.

### Pillar 2: Observability & Audit

**Question:** What happened, and can you prove it?

Three complementary layers:

| Layer | Source | What it captures |
|-------|--------|-----------------|
| **Platform audit** | `system.access.audit` | SQL queries, UC operations, identity, timestamp |
| **App audit** | Custom Delta table | Tool calls, human email (behind SP), latency, errors |
| **MLflow traces** | MLflow experiment | Full request/response, spans, tags, token usage |

The chain of custody is `human -> tool -> SQL -> data`, correlated across all three layers by `request_id`. Alerts fire on error-rate spikes, P95 latency breaches, safety-score drops, and unusual access patterns.

**Future-proof because:** Every new AI service writes to `system.access.audit`, so the platform audit surface grows automatically. Application audit is a pattern you implement once (decorator or middleware) and apply to every tool.

### Pillar 3: Agent Runtime Harness

**Question:** As an agent calls tools at runtime, does the caller's identity carry through, and can you see and constrain what it did?

The harness is the layer between an agent and the tools it calls, and it is where the two pillars above become operational. The user's identity is exchanged and propagated so tool calls and SQL run as the real caller, and every policy decision, tool call, and cost event becomes a trace or an audit record. Guardrails such as working-directory confinement, egress allowlists, blast-radius limits, and human-approval gates are expressed as policies with deterministic verdicts, so they are testable rather than aspirational. See [harness/](harness/) and the runnable [omnigent-guardrails-demo/](harness/omnigent-guardrails-demo/).

**Future-proof because:** Every agent runtime faces the same two questions, whose identity flows through and what you can observe and constrain. The tools and models change; the identity-and-observability boundary does not.

## The Adaptability Model

The framework is designed to absorb change at every layer:

| What changes | What stays the same | How it adapts |
|---|---|---|
| New AI service (e.g., Databricks adds a new agent type) | UC governance, identity model, audit surface | New service issues SQL; governance fires automatically |
| New external tool (e.g., new MCP server) | Connection governance, confused deputy defense | `CREATE CONNECTION` + `GRANT USE CONNECTION`: one SQL command |
| New identity source (e.g., new IDP) | Token exchange, SP mapping, UC groups | Update federation policy; same SP architecture, same UC groups |
| New compliance requirement (e.g., new data classification) | ABAC framework, governed tags | Add tag + row filter; no code changes |
| New attack surface (e.g., prompt injection via tool) | Defense in depth: each layer denies independently | UC enforcement at SQL layer blocks unauthorized data access regardless of prompt manipulation. Prompt security is a cross-cutting concern addressing identity (who sent the prompt), data governance (UC blocks unauthorized access regardless of injection), tool governance (tool description poisoning, response injection), and observability (detecting successful injection) |
| New AI coding tool or agent | Harness policy patterns | Context-aware policy verdicts adapt; the identity and observability boundary stays stable |

The pattern: **new capabilities are additive, not architectural**. You never redesign the governance framework. You extend it by adding a connection, a grant, a tag, or a policy.

---

## Where Databricks Fits

Databricks is not a governance vendor. It's a data and AI platform that happens to have governance built into its execution layer. This distinction matters:

- **Unity Catalog is not a policy engine bolted on top:** it's the execution layer. Row filters fire inside the SQL engine, not in a proxy. They cannot be bypassed.
- **OAuth scopes are not an authorization system:** they're a capability ceiling. UC grants are the actual authorization. Scopes limit what the token CAN do; grants determine what the identity MAY do.
- **`system.access.audit` is not a logging feature:** it's a record of every governance decision the platform made. It's the ground truth.

The competitive moat: no other platform has a single governance plane that spans SQL, AI agents, model serving, vector search, external connections, and serverless compute. Competitors have pieces (Snowflake has data governance, Azure has network controls, AWS has IAM). Databricks has the unified plane.

---

## Using This Repository

This repository's reference documentation is organized around the pillars:

| Pillar | Key Documents |
|--------|--------------|
| Identity & Access | [Identity/](identity/): [Authentication](identity/authentication.md), [Authorization](identity/authorization.md), [Federation](identity/federation.md), [Proxy Architecture](identity/proxy-architecture.md), [OAuth Scopes](identity/oauth-scopes-reference.md), [Cloud Auth Patterns](identity/cloud-auth-patterns.md), [Service Principal M2M](identity/sp-m2m-identity.md), [U2M External OBO](identity/u2m-external-obo.md) |
| Observability & Audit | [Observability/](observability/): [Audit Reference](observability/audit-reference.md), [Agent Tracing](observability/agent-tracing.md), [App Observability](observability/app-observability.md), [Endpoint Telemetry](observability/endpoint-telemetry.md) |
| Agent Runtime Harness | [Harness/](harness/): [Omnigent Guardrails Demo](harness/omnigent-guardrails-demo/) (identity and observability at the agent runtime boundary) |

The presentation library ([presentations/](https://bhavink.github.io/applied-ai-governance/presentations/)) spans 14 talks covering identity, authorization, federation, cost control, UC governance, orchestration, and the applied AI governance model end-to-end.

The network perimeter, data-layer filtering (UC row filters and column masks), connection governance (UC Connections), and compliance-as-SQL are enforced through Databricks platform features and are cited to the public documentation where they come up, rather than restated as reference docs here. Prompt security is a cross-cutting concern addressed within the identity, observability, and harness pillars.

---

*The tools will change. The principles won't. Govern the invariants.*
