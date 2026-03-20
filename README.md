# Applied AI Governance

> *The tools will change. The principles won't. Govern the invariants.*

Production-ready governance patterns for AI applications on Databricks -- identity, data, tools, network, and audit across Genie, Agent Bricks, Apps, Model Serving, and custom MCP servers.

**Start here:** [Governance Framework](GOVERNANCE-FRAMEWORK.md) -- the seven pillars, design principles, and adaptability model that underpin everything in this repo.

---

## The Seven Pillars

| # | Pillar | Status | Path |
|---|--------|--------|------|
| 0 | [Developer Guardrails](developer-guardrails/) | Planned | Build-time safety for AI coding tools |
| 1 | [Network Access Controls](network/) | Cross-link | Private Link, VPC-SC, NCC ([bhavink/databricks](https://github.com/bhavink/databricks)) |
| 2 | [Identity & Access Control](identity/) | Active | OBO, M2M, Federation, OAuth scopes |
| 3 | [Data Governance](data-governance/) | Active | Row filters, column masks, ABAC, UC privileges |
| 4 | [Tool & API Governance](tool-governance/) | Active | AI Gateway, MCP, UC Connections |
| 5 | [Observability & Audit](observability/) | Active | System tables, MLflow traces, dashboards |
| 6 | [Policy & Compliance](policy-compliance/) | Planned | Governance-as-SQL, drift detection, evidence |

---

## Quick Start

New to Databricks AI governance? Read these in order:

1. [Authentication Patterns](identity/authentication-patterns.md) -- Three universal patterns (M2M, OBO, Federation)
2. [UC Authorization](data-governance/uc-authorization.md) -- UC governance: privileges, ABAC, row filters, column masks
3. [UC Policy Design](data-governance/uc-policy-design.md) -- `current_user()` vs `is_member()` across all execution contexts

---

## Reference Docs

| Document | Pillar | Contents |
|----------|--------|----------|
| [Identity Reference](identity/identity-reference.md) | Identity | 16-service identity map, token flows, OAuth scope map, product gaps |
| [OBO vs M2M Matrix](identity/obo-vs-m2m-decision-matrix.md) | Identity | Decision tree, per-service examples, anti-patterns |
| [Authorization Flows](identity/authorization-flows.md) | Identity | Hop-by-hop header traces, proxy architectures |
| [Federation Exchange](identity/federation-exchange.md) | Identity | IDP swap guide, enforcement points, role-based SPs |
| [Genie Cookbook](data-governance/genie-authorization-cookbook.md) | Data | Multi-team Genie access for 1000+ users |
| [AI Gateway Patterns](tool-governance/ai-gateway-patterns.md) | Tools | Databricks AI Gateway vs external gateway vs UC-native |
| [Orchestration Architecture](tool-governance/orchestration-architecture.md) | Tools | Model Serving, MCP, AI Gateway, Lakebase |
| [Audit Reference](observability/audit-reference.md) | Observability | Scorers, dashboards, correlation queries, alerts |

---

## Interactive Visualizations

| Page | Concept | Link |
|------|---------|------|
| Orchestration Hub | Architecture overview | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/) |
| Agent Auth Methods | Model Serving auth patterns | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/agent-auth-methods.html) |
| External App Auth | Token federation for external apps | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/external-app-auth.html) |
| MCP Integration | Managed, External, Custom MCP patterns | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/mcp-integration.html) |
| AI Gateway Governance | Rate limits, guardrails, inference tables | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/ai-gateway-governance.html) |
| Databricks Apps | Native OAuth, UC integration | [View](https://bhavink.github.io/applied-ai-governance/interactive/orchestration/databricks-apps.html) |
| Access Control Layers | UC four-layer authorization | [View](https://bhavink.github.io/applied-ai-governance/interactive/uc-access-control-layers.html) |
| ABAC + Governed Tags | Tag-based dynamic access control | [View](https://bhavink.github.io/applied-ai-governance/interactive/uc-abac-governed-tags.html) |
| Row Filters | Row-level security | [View](https://bhavink.github.io/applied-ai-governance/interactive/uc-row-filters.html) |
| Column Masks | Column-level security | [View](https://bhavink.github.io/applied-ai-governance/interactive/uc-column-masks.html) |
| OBO Auth Flow | On-Behalf-Of-User authentication | [View](https://bhavink.github.io/applied-ai-governance/interactive/auth-flow-obo.html) |
| Federation Token Flow | 10-step animated token exchange | [View](https://bhavink.github.io/applied-ai-governance/interactive/federation-token-flow.html) |
| Decision Guide | Choose the right pattern | [View](https://bhavink.github.io/applied-ai-governance/interactive/decision-guide.html) |

---

## Presentations

| # | Deck | Audience | Topic |
|---|------|----------|-------|
| 1 | [Identity & Governance Overview](presentations/identity-governance-overview.html) | Exec | OBO vs M2M vs Federation, shared UC governance, scope model -- 18 slides |
| 2 | [Federation Animation](presentations/federation-animation.html) | Exec | Interactive token flow animation with token inspector |
| 3 | [Federation Deep Dive](presentations/federation-deep-dive.html) | Technical | Token anatomy, enforcement points, grants checklist, embedded animation -- 21 slides |
| 4 | [AI Gateway Patterns](presentations/ai-gateway-patterns-v2.html) | Technical | AI Gateway traffic patterns and decision framework |

---

## Common Questions

**Q: Which authentication pattern should I use?**
A: See the [OBO vs M2M Decision Matrix](identity/obo-vs-m2m-decision-matrix.md).

**Q: How do I enforce per-user data access?**
A: Use OBO + UC row filters. See [UC Authorization](data-governance/uc-authorization.md).

**Q: How do I secure a Genie Space for multiple teams?**
A: See the [Genie Authorization Cookbook](data-governance/genie-authorization-cookbook.md).

**Q: My custom MCP server always shows the SP identity, not the user. Why?**
A: This is the two-proxy problem. See [Identity Reference](identity/identity-reference.md).

**Q: Why does `is_member()` return the same result for all Genie users?**
A: Under OBO, `is_member()` may evaluate the execution identity, not the calling user. Use `current_user()` + allowlist table. See [UC Policy Design](data-governance/uc-policy-design.md).

**Q: How do I audit access when using M2M?**
A: Platform audit records the SP UUID. You need app-level logging with `X-Forwarded-Email` for human identity. See [Audit Reference](observability/audit-reference.md).

**Q: How do I give external users governed access to Databricks AI tools?**
A: Use Federation Exchange: external IDP JWT -> Databricks token exchange -> role-based SPs -> UC governance. See [Federation Exchange](identity/federation-exchange.md).

**Q: What's the difference between OBO and Federation?**
A: OBO = apps ON Databricks (user has a workspace account). Federation = apps OUTSIDE Databricks (user has no Databricks account, authenticates via external IDP). See the [Identity & Governance presentation](presentations/identity-governance-overview.html).

---

## Related Databricks Documentation

- [Agent Bricks](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/)
- [Agent Framework Authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html)
- [Access Control in UC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- [ABAC](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac)
- [Row Filters & Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)
- [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m.html)
- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m.html)
- [Databricks Apps](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html)
- [Genie Space](https://docs.databricks.com/aws/en/genie/)

---

*Last updated: 2026-03-20*
