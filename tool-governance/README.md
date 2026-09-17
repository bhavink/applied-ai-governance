# Tool & API Governance

> **Pillar 4**: What tools and external services can an agent call, and how is that access controlled and changed safely?

Agents act by calling tools: SQL, Genie Agents, Vector Search, Model Serving, and external APIs. This
pillar covers how a custom MCP server fronts those tools under a governed identity, and how the
policy that decides which role may call which tool is managed without redeploys.

## Reading Order

**Hands-on quickstart:** [Getting Started with `ug` (Formerly `ucode`)](ug-quickstart.md):
install, sign in, launch a coding agent, and understand its connection to Unity Gateway.

1. [Custom MCP Principles](custom-mcp-principles.md): the architecture of a custom MCP server
   that fronts Databricks data and compute. MCP as the single gateway, scopes over grants, UC
   governance end to end, external credentials via UC connections, full trace/audit coverage,
   rate limiting, and supervisor/multi-agent integration.
2. [Runtime Config Patterns](runtime-config-patterns.md): decoupling runtime policy (role
   mappings, tool-access matrices, persona/UI metadata) from code so it is hot-deployable,
   versioned, and provider-agnostic. Config as an API contract, UC-backed versioning with
   rollback, caching with fallback.

## The Key Insight

Separate the three things that get conflated: business logic belongs in code, infrastructure
IDs belong in deploy-time config, and runtime policy (who can call what) belongs in a governed
config store you can change in seconds. The MCP server is the choke point where scopes, UC
grants, and tool-level access all meet, so it is also where trace and audit coverage is
cheapest to make total.

## Presentations

- [Orchestration & Tool Governance (Deck 05)](https://bhavink.github.io/applied-ai-governance/presentations/05-orchestration-tool-governance.html): Agent Bricks orchestration, MCP types, service policies for tool-calling agents.
- [Service Principal & M2M (Deck 07)](https://bhavink.github.io/applied-ai-governance/presentations/07-sp-m2m-identity.html): one SP per service, purpose-scoped groups, client-credentials flow.
- [UC Connections (Deck 08)](https://bhavink.github.io/applied-ai-governance/presentations/08-uc-connections.html): governed external service access without static secrets.

## Related Pillars

- [Identity & Access Control](../identity/): how a governed token reaches the MCP server, and
  how scopes and UC grants compose.
- [Data Governance](../data-governance/): the row filters and column masks that fire when a
  tool issues SQL under the caller's identity.
- [Observability & Audit](../observability/): the trace and audit records every tool call emits.
