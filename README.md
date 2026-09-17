# Applied AI Governance

> *The tools will change. The principles won't. Govern the invariants.*

**[View the rendered site and presentation decks](https://bhavink.github.io/applied-ai-governance/)**. The decks render on the Pages site, so open links there to see the published slides rather than raw HTML.

Your business needs an AI platform where users get governed answers from live data, knowledge workers search across institutional memory, and agents orchestrate complex workflows, all while partners and customers access the same capabilities through their own identity providers without platform accounts. This repository is a gold standard for building and governing that platform on Databricks, with a focus on identity, data governance, tool and API governance, observability, and the agent runtime harness.

**Start here:** [Governance Framework](GOVERNANCE-FRAMEWORK.md) defines the design principles and adaptability model.

---

## Core Reference Docs

| Topic | Path | Contents |
|-------|------|----------|
| Identity & Access Control | [identity/](identity/) | AuthN (IdP delegation), AuthZ (OBO, M2M, Federation), [production federation guide](identity/federation-production.md), [service identity & audit](identity/service-identity-and-audit.md), [federation personas](identity/federation-personas-patterns.md), [proxy architecture](identity/proxy-architecture.md), [OAuth scopes](identity/oauth-scopes-reference.md) |
| Data Governance | [data-governance/](data-governance/) | [Access control patterns](data-governance/access-control-patterns.md): row filters, column masks, ABAC, and the service-principal identity gap for federated access |
| Tool & API Governance | [tool-governance/](tool-governance/) | [Custom MCP principles](tool-governance/custom-mcp-principles.md) (gateway, scopes over grants, UC connections) and [runtime config patterns](tool-governance/runtime-config-patterns.md) (hot-deployable tool policy) |
| Observability & Audit | [observability/](observability/) | Platform audit (system.access.audit), application audit patterns, [MLflow tracing](observability/agent-tracing.md), [app observability](observability/app-observability.md), audit correlation |
| Agent Runtime Harness | [harness/](harness/) | Identity and observability at the agent runtime boundary, [omnigent guardrails demo](harness/omnigent-guardrails-demo/), policy enforcement |

---

## Quick Start

**Coding agents:** [Getting Started with `ug` (Formerly `ucode`)](tool-governance/ug-quickstart.md) — install, authenticate, and connect your coding agent to Unity Gateway.

1. [Authentication](identity/authentication.md): AuthN is delegated to IdPs (brief overview + official doc links)
2. [Authorization](identity/authorization.md): The three token patterns, OAuth scopes, service principals, federation
3. [Audit & Tracing](observability/agent-tracing.md): Platform audit, MLflow traces, chain of custody for compliance

---

## Presentation Library

Browse the full collection of governance talks and reference decks: [Presentations](https://bhavink.github.io/applied-ai-governance/presentations/)

---

## Common Questions

**Q: Which authentication pattern should I use?**
A: See the decision table in [Authorization](identity/authorization.md#choosing-the-right-pattern).

**Q: How do I enforce per-user data access?**
A: Use OBO tokens to propagate user identity into SQL queries. Unity Catalog row filters and column masks enforce access automatically. See [Row Filters & Column Masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/).

**Q: My custom MCP server always shows the SP identity, not the user. Why?**
A: This is the two-proxy problem. See [Authorization](identity/authorization.md#the-three-token-patterns).

**Q: How do I give external users governed access to Databricks AI tools?**
A: Use token federation. Start with the [Production Federation Guide](identity/federation-production.md) to choose between per-user and role-based, then [Federation](identity/federation.md) and the [Federation Blueprint](identity/federation-implementation-blueprint.md) for the build.

**Q: My row filter using `current_user()` returns no rows for a federated user. Why?**
A: When an external user reaches Databricks through a service principal, `current_user()` is the SP, not the human, so individual-identity filters do not fire. Use group-based filtering (or a mapping table). See [Access Control Patterns](data-governance/access-control-patterns.md).

**Q: How do I change which role can call which tool without a redeploy?**
A: Keep the tool-access matrix in a governed, versioned config store the server reads at runtime, not in code. See [Runtime Config Patterns](tool-governance/runtime-config-patterns.md).

**Q: My host app's IdP is different from the Databricks account's IdP. How do I embed a dashboard without a second login?**
A: Use Embedding for External Users (SP-based token mint), not Basic Embedding. Migrating the account's IdP (Automatic Identity Management) does not solve this for external viewers. See [Deck 11](https://bhavink.github.io/applied-ai-governance/presentations/11-aibi-dashboard-embedding.html).

**Q: How do I govern which identities can call external services?**
A: Use UC HTTP Connections with GRANT/REVOKE USE CONNECTION. This enforces the governance decision at the SQL engine, preventing confused deputy attacks. See [UC HTTP Connections](https://docs.databricks.com/aws/en/query-federation/http).

**Q: Can an agent or app access a user's personal Google Drive or Gmail?**
A: Yes, using OAuth U2M Per User connections. Each user authenticates separately. See [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m).

---

## Related Databricks Documentation

Everything in this repository is grounded in public Databricks documentation. The primary sources are collected here; individual docs link to the specific pages they draw on.

- [Unified client authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) | [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)
- [Databricks Apps](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html) | [App authentication](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth) | [App resources](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/resources)
- [Agent Framework](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent) | [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html) | [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) | [Row Filters & Column Masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/) | [ABAC tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)
- [UC HTTP Connections](https://docs.databricks.com/aws/en/query-federation/http)
- [Genie Agent](https://docs.databricks.com/aws/en/genie/)
- [Security overview](https://docs.databricks.com/aws/en/security/)

---

*Last updated: 2026-09-16*
