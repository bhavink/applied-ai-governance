# Tool & API Governance

> **Pillar 4**: Can this identity use this external tool or service?

UC Connections govern external service access. `GRANT USE CONNECTION` is the on/off switch. This is how you prevent the confused deputy: no redeployment, no code changes, instant effect.

## Reading Order

1. [AI Gateway Patterns](ai-gateway-patterns.md): When to use Databricks AI Gateway vs external gateway vs UC-native controls
2. [Orchestration Architecture](orchestration-architecture.md): Governed AI orchestration across Model Serving, MCP, AI Gateway, and Lakebase

## Key Concepts

- **UC Connections**: The governance primitive for external tool access. Bearer token, OAuth, or managed credential.
- **USE CONNECTION**: SQL grant that controls which identities can call which external services.
- **Confused Deputy Defense**: A privileged MCP server cannot be tricked into calling external APIs on behalf of an unauthorized user.
- **Two-Layer Defense**: Application RBAC (which roles can call which tools) + UC enforcement (which identities can USE which connections).

## Related Pillars

- [Identity](../identity/): Identity model determines which SP/user is checked for USE CONNECTION
- [Data Governance](../data-governance/): Row filters and column masks govern data; connections govern tools
- [Observability](../observability/): Every USE CONNECTION attempt is audited in system tables
