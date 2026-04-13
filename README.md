# Applied AI Governance

> *The tools will change. The principles won't. Govern the invariants.*

Your business needs an AI platform where users get governed answers from live data, knowledge workers search across institutional memory, and agents orchestrate complex workflows, all while partners and customers access the same capabilities through their own identity providers without platform accounts. This repository shows you how to build and govern that platform on Databricks.

**Start here:** [Governance Framework](GOVERNANCE-FRAMEWORK.md) defines the seven pillars, design principles, and adaptability model.

---

## Pillars

| Pillar | Path | Contents |
|--------|------|----------|
| Identity & Access Control | [identity/](identity/) | AuthN (IdP delegation), AuthZ (OBO, M2M, Federation), [proxy architecture](identity/proxy-architecture.md), [OAuth scopes](identity/oauth-scopes-reference.md), [cloud auth](identity/cloud-auth-patterns.md), SPs |
| Data Governance | [data-governance/](data-governance/) | Row filters, column masks, ABAC, group gotchas, best practices, Genie multi-team patterns |
| Tool & API Governance | [tool-governance/](tool-governance/) | AI Gateway patterns, [MCP governance](tool-governance/mcp-governance.md), [agent governance](tool-governance/agent-governance.md), UC HTTP Connections |
| Prompt Security | [prompt-security/](prompt-security/) | Attack surfaces (9), hardening patterns, [threat intel log](prompt-security/threat-intel-log.md), defense-in-depth |
| Observability & Audit | [observability/](observability/) | Two-layer model, system tables, MLflow tracing patterns, audit correlation |

Network, developer guardrails, and policy/compliance pillars are defined in the [Governance Framework](GOVERNANCE-FRAMEWORK.md) and will be added as content is built and validated.

---

## Quick Start

1. [Authentication](identity/authentication.md): AuthN is delegated to IdPs (brief overview + official doc links)
2. [Authorization](identity/authorization.md): The three token patterns, UC governance, OAuth scopes, service principals
3. [UC Governance](data-governance/uc-governance.md): Row filters, column masks, ABAC, Genie patterns

---

## Presentations

| # | Deck | Audience | Topic |
|---|------|----------|-------|
| 01 | [AI Governance — The Complete Picture](https://bhavink.github.io/applied-ai-governance/presentations/01-ai-governance-complete.html) | Exec | One auth layer, three token paths, six enforcement layers, resource auth matrix, decision trees, prerequisites checklists |
| 02 | [Identity & Authorization by Resource Type](https://bhavink.github.io/applied-ai-governance/presentations/02-identity-authorization-by-resource.html) | Technical | Serving Endpoints, Genie, UC Functions, Vector Search, UC HTTP Connections, Tables, Lakebase — auth model, identity flow, and gotchas for each |
| 03 | [AI Orchestration & Tool Governance](https://bhavink.github.io/applied-ai-governance/presentations/03-ai-orchestration-tool-governance.html) | Technical | Agent Bricks, MCP servers, UC Connections, token federation, AI Gateway, observability — end-to-end orchestration governance |

**Implementation Guides:**

| # | Guide | Topic |
|---|-------|-------|
| IG | [Federation Token Exchange — Implementation Blueprint](https://bhavink.github.io/applied-ai-governance/presentations/federation-implementation-blueprint.html) | 12 prerequisites, 7-step flow, Auth0 / Okta / Entra ID walkthroughs, error catalog, smoke tests |

Previous versions (identity-governance-overview, identity-patterns, federation-deep-dive, uc-governance, orchestration, ai-gateway-patterns-v2, uc-connections) are archived in the [presentations directory](https://bhavink.github.io/applied-ai-governance/presentations/).

Browse all decks: [Presentations](https://bhavink.github.io/applied-ai-governance/presentations/)

---

## Common Questions

**Q: Which authentication pattern should I use?**
A: See the decision table in [Authorization](identity/authorization.md#choosing-the-right-pattern).

**Q: How do I enforce per-user data access?**
A: Use OBO + UC row filters. See [UC Authorization](data-governance/uc-governance.md).

**Q: How do I secure a Genie Space for multiple teams?**
A: See the Genie patterns section in [UC Governance](data-governance/uc-governance.md#genie-space-patterns).

**Q: My custom MCP server always shows the SP identity, not the user. Why?**
A: This is the two-proxy problem. See [Authorization](identity/authorization.md#the-three-token-patterns).

**Q: How do I give external users governed access to Databricks AI tools?**
A: Use Federation Exchange. See [Federation](identity/federation.md).

**Q: How do I govern which agents can call external APIs?**
A: Use UC HTTP Connections with `GRANT USE CONNECTION`. See [UC Connections](tool-governance/uc-connections.md).

**Q: Can an agent access a user's personal Google Drive or Gmail?**
A: Yes, using OAuth U2M Per User connections. Each user authenticates separately. See [UC Connections](tool-governance/uc-connections.md#oauth-u2m-per-user).

---

## Related Databricks Documentation

- [Unified client authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) | [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)
- [Databricks Apps](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html) | [App auth](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth) | [App resources](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/resources)
- [Agent Framework](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent) | [Agent auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html) | [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) | [ABAC tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)
- [Row Filters & Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)
- [Genie Space](https://docs.databricks.com/aws/en/genie/)
- [Security overview](https://docs.databricks.com/aws/en/security/)

---

*Last updated: 2026-04-13*
