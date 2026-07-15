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

| # | Deck | Topic |
|---|------|-------|
| 01 | [AI Governance — Complete Picture](https://bhavink.github.io/applied-ai-governance/presentations/01-ai-governance-complete.html) | Entry point: the overall governance model, linking out to every deeper deck below |
| 02 | [Unity AI Gateway](https://bhavink.github.io/applied-ai-governance/presentations/02-unity-ai-gateway.html) | Identity, runtime, and observability for every LLM, MCP, and API call. Guardrail templates, rate limits, spend caps, service policies, native provider APIs, and where a gateway should never sit — the OBO request path |
| 03 | [Identity & Auth Foundations](https://bhavink.github.io/applied-ai-governance/presentations/03-identity-auth-foundations.html) | One IdP layer, U2M/OBO/M2M token paths, auth vs authz, decision guide |
| 04 | [Authorization by Resource Type](https://bhavink.github.io/applied-ai-governance/presentations/04-authorization-by-resource.html) | Auth mechanics per resource: serving endpoints, Genie, Vector Search, UC Functions, UC HTTP Connections, Lakebase |
| 05 | [Orchestration & Tool Governance](https://bhavink.github.io/applied-ai-governance/presentations/05-orchestration-tool-governance.html) | Agent Bricks supervisor/sub-agent identity, agent auth methods, MCP three types, UC Connections as the governance primitive |
| 06 | [Cross-IdP Federation](https://bhavink.github.io/applied-ai-governance/presentations/06-cross-idp-federation.html) | External, foreign-IdP users into Databricks-governed apps without a second login or losing per-user governance. Two-leg token exchange, per-user OBO vs. role-based SP, federation policy config, current_user() vs. is_member(), prerequisites and go/no-go checklist |
| 07 | [Service Principal Identity & M2M Governance](https://bhavink.github.io/applied-ai-governance/presentations/07-sp-m2m-identity.html) | One SP per service, SP→Group→UC GRANT chain, client credentials flow, current_user() UUID behavior, secret scope management, audit trail |
| 08 | [UC HTTP Connections](https://bhavink.github.io/applied-ai-governance/presentations/08-uc-connections.html) | Bearer token, OAuth M2M, U2M shared/per-user, GRANT/REVOKE USE CONNECTION as the governance switch |
| 09 | [Unity Catalog Governance](https://bhavink.github.io/applied-ai-governance/presentations/09-uc-governance.html) | Four-layer access control, row filters, column masks, ABAC |
| 10 | [AI Agent Cost Control & Governance](https://bhavink.github.io/applied-ai-governance/presentations/10-agent-cost-governance.html) | Claude Code, Codex, Gemini routed through Unity Gateway. Model allowlisting, rate limits, hard spend caps, guardrails, service policies, sandbox isolation |
| 11 | [AI/BI Dashboard Embedding Without a Second Login](https://bhavink.github.io/applied-ai-governance/presentations/11-aibi-dashboard-embedding.html) | Embedding a dashboard behind a foreign IdP without a second login prompt: two embedding models compared, SP-based 3-step token mint, `__aibi_external_value` scoping (app-enforced, not UC row filters) |
| 12 | [Answers Scoped to the Person Asking — Teams & Copilot Studio](https://bhavink.github.io/applied-ai-governance/presentations/12-teams-copilot-genie-obo.html) | Per-user identity into Genie/Agent Bricks from Microsoft Teams and Copilot Studio: integration paths mapped, the "two gates" insight (token-layer OBO + Genie space publish mode) |

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

**Q: My host app's IdP is different from the Databricks account's IdP. How do I embed a dashboard without a second login?**
A: Use Embedding for External Users (SP-based token mint), not Basic Embedding. Migrating the account's IdP (Automatic Identity Management) doesn't solve this for external viewers. See [Deck 11](https://bhavink.github.io/applied-ai-governance/presentations/11-aibi-dashboard-embedding.html).

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

*Last updated: 2026-07-14*

