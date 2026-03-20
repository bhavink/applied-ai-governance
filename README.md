# Applied AI Governance

> *The tools will change. The principles won't. Govern the invariants.*

Production-ready governance patterns for AI applications on Databricks. Identity, data, tools, network, and audit across Genie, Agent Bricks, Apps, Model Serving, and custom MCP servers.

**Start here:** [Governance Framework](GOVERNANCE-FRAMEWORK.md) defines the seven pillars, design principles, and adaptability model.

---

## Pillars

| Pillar | Path | Contents |
|--------|------|----------|
| Identity & Access Control | [identity/](identity/) | AuthN (IdP delegation), AuthZ (OBO, M2M, Federation), UC governance, scopes, SPs |
| Data Governance | [data-governance/](data-governance/) | Row filters, column masks, ABAC, governed tags, Genie multi-team patterns |
| Tool & API Governance | [tool-governance/](tool-governance/) | AI Gateway, MCP, UC Connections, orchestration |
| Observability & Audit | [observability/](observability/) | System tables, MLflow traces, audit patterns |

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
| 1 | [Identity & Governance Overview](https://bhavink.github.io/applied-ai-governance/presentations/identity-governance-overview.html) | Exec | OBO vs M2M vs Federation, shared UC governance, scope model |
| 2 | [Federation Deep Dive](https://bhavink.github.io/applied-ai-governance/presentations/federation-deep-dive.html) | Technical | Token anatomy, enforcement points, grants checklist |
| 3 | [Identity Patterns](https://bhavink.github.io/applied-ai-governance/presentations/identity-patterns.html) | Technical | OBO, M2M, Federation flows, decision guide, scopes, SPs |
| 4 | [UC Governance](https://bhavink.github.io/applied-ai-governance/presentations/uc-governance.html) | Technical | Four-layer access control, row filters, column masks, ABAC |
| 5 | [Orchestration](https://bhavink.github.io/applied-ai-governance/presentations/orchestration.html) | Technical | Agents, Apps, MCP, AI Gateway, external auth |
| 6 | [AI Gateway Patterns](https://bhavink.github.io/applied-ai-governance/presentations/ai-gateway-patterns-v2.html) | Technical | Gateway traffic patterns and decision framework |

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

*Last updated: 2026-03-20*
