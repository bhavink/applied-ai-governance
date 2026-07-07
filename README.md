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
| 01 | [AI Governance — The Complete Picture](https://bhavink.github.io/applied-ai-governance/presentations/01-ai-governance-complete.html) | Exec | Three token paths, seven enforcement layers (incl. Service Policies + MCP Services), resource auth matrix, BROWSE privilege, decision trees |
| 02 | [Identity, Authorization & Orchestration — Technical Reference](https://bhavink.github.io/applied-ai-governance/presentations/02-identity-auth-orchestration.html) | Technical | Three token paths, auth-by-resource matrix (7 resources), per-resource gotchas, Agent Bricks orchestration, MCP three types, UC HTTP Connections, end-to-end animated flow, 8 failure patterns |
| 03 | [E2E User Identity Propagation — Cross-IdP Token Exchange](https://bhavink.github.io/applied-ai-governance/presentations/05-cross-idp-token-exchange.html) | Technical | External app + customer IdP + Databricks data as one identity chain. JWKS decision gate, RFC 8693 POST, UC current_user() enforcement, gotchas, IdP team checklist |
| 04 | [Unity AI Gateway — Capability Deep Dive](https://bhavink.github.io/applied-ai-governance/presentations/06-unity-ai-gateway-capabilities.html) | Technical | Eight capabilities via Acme Financial user story. Routing, rate limits, guardrails, service policies, spend caps, MCP Services, prompt registry |
| 05 | [AI Agent Cost Control & Governance](https://bhavink.github.io/applied-ai-governance/presentations/07-agent-cost-governance.html) | Technical | Claude Code, Codex, Gemini routed through Unity Gateway. Six governance layers: model allowlisting, rate limits, hard spend caps, guardrails, service policies, sandbox isolation |
| 06 | [Service Principal Identity & M2M Governance](https://bhavink.github.io/applied-ai-governance/presentations/08-sp-m2m-identity.html) | Technical | One SP per service, SP→Group→UC GRANT chain, client credentials flow, current_user() UUID behavior, secret scope management, audit trail. Completes the identity story from Deck 03 |

**Implementation Guides:**

| # | Guide | Topic |
|---|-------|-------|
| IG | [Federation Token Exchange — Implementation Blueprint](https://bhavink.github.io/applied-ai-governance/presentations/federation-implementation-blueprint.html) | 12 prerequisites, 7-step flow, Auth0 / Okta / Entra ID walkthroughs, error catalog, smoke tests. Companion to Decks 02 and 03 |

Browse all decks (including archived previous versions): [Presentations](https://bhavink.github.io/applied-ai-governance/presentations/)

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

*Last updated: 2026-07-07*
