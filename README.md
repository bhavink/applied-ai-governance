# Applied AI Governance

> *The tools will change. The principles won't. Govern the invariants.*

Your business needs an AI platform where users get governed answers from live data, knowledge workers search across institutional memory, and agents orchestrate complex workflows, all while partners and customers access the same capabilities through their own identity providers without platform accounts. This repository is a gold standard for building and governing that platform on Databricks, with a focus on identity, observability, and the agent runtime harness.

**Start here:** [Governance Framework](GOVERNANCE-FRAMEWORK.md) defines the design principles and adaptability model.

---

## Core Reference Docs

| Topic | Path | Contents |
|-------|------|----------|
| Identity & Access Control | [identity/](identity/) | AuthN (IdP delegation), AuthZ (OBO, M2M, Federation), [proxy architecture](identity/proxy-architecture.md), [OAuth scopes](identity/oauth-scopes-reference.md), [cloud auth patterns](identity/cloud-auth-patterns.md), service principal governance |
| Observability & Audit | [observability/](observability/) | Platform audit (system.access.audit), application audit patterns, [MLflow tracing](observability/agent-tracing.md), [app observability](observability/app-observability.md), audit correlation |
| Agent Runtime Harness | [harness/](harness/) | Identity and observability at the agent runtime boundary, [omnigent guardrails demo](harness/omnigent-guardrails-demo/), policy enforcement |

---

## Quick Start

1. [Authentication](identity/authentication.md): AuthN is delegated to IdPs (brief overview + official doc links)
2. [Authorization](identity/authorization.md): The three token patterns, OAuth scopes, service principals, federation
3. [Audit & Tracing](observability/agent-tracing.md): Platform audit, MLflow traces, chain of custody for compliance

---

## Presentation Library

Browse the full collection of 14 governance talks and reference decks: [Presentations](presentations/)

---

## Common Questions

**Q: Which authentication pattern should I use?**
A: See the decision table in [Authorization](identity/authorization.md#choosing-the-right-pattern).

**Q: How do I enforce per-user data access?**
A: Use OBO tokens to propagate user identity into SQL queries. Unity Catalog row filters and column masks enforce access automatically. See [Row Filters & Column Masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/).

**Q: My custom MCP server always shows the SP identity, not the user. Why?**
A: This is the two-proxy problem. See [Authorization](identity/authorization.md#the-three-token-patterns).

**Q: How do I give external users governed access to Databricks AI tools?**
A: Use Federation Exchange. See [Federation](identity/federation.md) and [Federation Blueprint](identity/federation-implementation-blueprint.md).

**Q: My host app's IdP is different from the Databricks account's IdP. How do I embed a dashboard without a second login?**
A: Use Embedding for External Users (SP-based token mint), not Basic Embedding. Migrating the account's IdP (Automatic Identity Management) does not solve this for external viewers. See [Deck 11](https://bhavink.github.io/applied-ai-governance/presentations/11-aibi-dashboard-embedding.html).

**Q: How do I govern which identities can call external services?**
A: Use UC HTTP Connections with GRANT/REVOKE USE CONNECTION. This enforces the governance decision at the SQL engine, preventing confused deputy attacks. See [UC HTTP Connections](https://docs.databricks.com/aws/en/query-federation/http).

**Q: Can an agent or app access a user's personal Google Drive or Gmail?**
A: Yes, using OAuth U2M Per User connections. Each user authenticates separately. See [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m).

---

## Related Databricks Documentation

- [Unified client authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) | [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)
- [Databricks Apps](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html) | [App authentication](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth) | [App resources](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/resources)
- [Agent Framework](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent) | [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html) | [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) | [Row Filters & Column Masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/) | [ABAC tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)
- [UC HTTP Connections](https://docs.databricks.com/aws/en/query-federation/http)
- [Genie Space](https://docs.databricks.com/aws/en/genie/)
- [Security overview](https://docs.databricks.com/aws/en/security/)

---

*Last updated: 2026-09-15*

