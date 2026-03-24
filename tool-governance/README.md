# Tool & API Governance

> **Pillar 4**: Can this identity use this external tool or service?

UC Connections govern external service access. `GRANT USE CONNECTION` is the on/off switch. This is how you prevent the confused deputy: no redeployment, no code changes, instant effect.

## Reading Order

1. [AI Gateway Patterns](ai-gateway-patterns.md): Four traffic patterns (internal, LLM governance, outbound external, inbound external) and when to use each
2. [UC Connections](uc-connections.md): Four authentication methods (Bearer, M2M, U2M Shared, U2M Per User), setup walkthrough, governance model

## Key Concepts

- **UC HTTP Connections**: The governance primitive for external tool access. Stores credentials centrally; app code never touches raw keys.
- **USE CONNECTION**: SQL grant that controls which identities can call which external services. Instant grant/revoke.
- **Four Auth Methods**: Bearer Token (static, shared), OAuth M2M (auto-refresh, shared), U2M Shared (one user authorizes for all), U2M Per User (true per-user identity at external service).
- **Confused Deputy Defense**: A privileged MCP server cannot be tricked into calling external APIs on behalf of an unauthorized user. USE CONNECTION checks the calling identity, not the server's identity.
- **Defense-in-Depth**: Serverless Network Policies (network layer) + UC Connections (credential layer). Neither alone is sufficient.

## Related Pillars

- [Identity](../identity/): Identity model determines which SP/user is checked for USE CONNECTION
- [Data Governance](../data-governance/): Row filters and column masks govern data; connections govern tools
- [Observability](../observability/): Every USE CONNECTION attempt is audited in system tables
