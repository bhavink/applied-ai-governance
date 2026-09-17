# Custom MCP Server Principles

> How to build a custom MCP server that fronts Databricks data and compute so that every tool
> call runs under a governed identity, external credentials never live in code, and every call
> is traced and audited. The identity mechanics (how a token reaches the server) live in the
> [identity pillar](../identity/federation-production.md); this doc is about what the server
> itself should enforce.

## Principles

1. **MCP is the single gateway.** Apps never call Databricks APIs directly; all data and
   compute access routes through MCP tools, so governance and audit have one choke point.
2. **Scopes over grants.** OAuth scopes restrict what a token can do; Unity Catalog
   (row filters, column masks, `USE CONNECTION`, `EXECUTE`) enforces fine-grained access.
   Minimize direct table grants.
3. **UC governance end to end.** Every tool invocation runs under the caller's identity, so
   row filters, column masks, and connection checks fire at the engine level.
4. **Full trace coverage.** Every tool call creates an MLflow trace with service, tool,
   caller, request id, latency, and status.
5. **Full audit coverage.** Every tool call writes an audit record (async, fire-and-forget):
   denials, errors, and successes alike.
6. **Defense in depth.** Tool-level RBAC (for the role-based path) plus UC governance plus
   scope restrictions. Multiple layers, any one of which is sufficient.
7. **No secrets in code.** External credentials live in Unity Catalog connections, retrieved
   at runtime via `USE CONNECTION`, not in environment variables.

## Identity into the server

The server accepts a token and runs tools under that identity. Two shapes are common, and
both map to the identity pillar's paths:

- **Role-based (external IdP -> role SP):** the app exchanges the user's IdP JWT for a
  role-scoped SP token (RFC 8693), forwards it to the server, and UC governance fires per the
  SP's group membership. See [Production Federation](../identity/federation-production.md)
  Path B.
- **Per-user (Databricks Apps proxy OBO):** the Apps proxy injects
  `X-Forwarded-Access-Token`, and UC governance fires as `current_user()` = the human. See
  Path C.

Whichever the source, the server calls Databricks with the supplied token; it does not
manufacture identity. Typical scopes carried on the token: `sql` (warehouse, where filters
and masks fire), `genie` (Conversation API), `serving` (Model Serving), and on Azure Genie
also `dashboards.genie`.

## Scope-based access model

| Resource | Scope required | UC grant required | Who checks |
|---|---|---|---|
| SQL warehouse | `sql` | `CAN USE` on warehouse | token + UC |
| Genie space | `genie` (+ `dashboards.genie` on Azure) | access to space + underlying tables | token + UC |
| Model Serving | `serving` | `CAN QUERY` on endpoint | token + UC |
| Vector Search | `sql` (SDK uses SQL internally) | `SELECT` on index | token + UC |
| UC connection | `sql` (for `DESCRIBE CONNECTION`) | `USE CONNECTION` | token + UC |
| UC function | `sql` (for `SELECT fn()`) | `EXECUTE` on function | token + UC |

The key insight: scopes restrict what the token can do; UC grants restrict what the identity
can access. The two layers enforce independently, so revoking either blocks access.

## External credentials via UC connections

Never store external secrets in environment variables or code. Register them as Unity Catalog
connections and gate access with `USE CONNECTION`.

```sql
CREATE CONNECTION external_api_conn
  TYPE HTTP
  OPTIONS (host 'https://api.example.com', bearer_token SECRET '<token>');

GRANT USE CONNECTION ON CONNECTION external_api_conn TO `sp-privileged-role`;
```

At runtime the server calls `DESCRIBE CONNECTION` with the caller's token so UC checks
`USE CONNECTION`; if allowed, it retrieves the credential, makes the external call, and the
access is captured in audit. Grant `USE CONNECTION` only to the roles that need it. Pair a
shared bearer-token connection (M2M) with a per-user managed-OAuth connection when some
callers should reach the external service as themselves rather than through a shared secret.

## Observability stack

```
tool call -> MLflow trace (spans: auth, sql, external_api, audit)
          -> audit table (async, never blocks the response)
          -> structured JSON logs (request_id correlation)
          -> dashboard (queries the audit table)
```

Minimum audit row: `request_id`, `request_time`, `external_user_email`, `role_mapped`,
`tool_name`, `status` (success/error/access_denied), `error_code`, `latency_ms`. MLflow trace
tags: `service_name`, `tool`, `caller.email`, `caller.role`, `request_id`, `status`,
`latency_ms`. See the [observability pillar](../observability/) for the full pattern.

## Rate limiting

| API | Limit | Strategy |
|---|---|---|
| Genie | ~5 queries/min/workspace | in-memory sliding window, return a retry hint |
| SQL | no hard limit | connection-pool limits (bounded concurrency) |
| Serving | per-endpoint | retry with backoff on 429 |
| External API | per token | retry with backoff on 429 |

## Supervisor / multi-agent integration

A custom MCP server can be registered as a sub-agent of a Databricks Supervisor Agent by
creating a UC connection to the server URL and adding it as an external MCP sub-agent. The
access control lever is `USE CONNECTION` on that connection: revoking it removes the MCP from
the user's supervisor experience at runtime. The supervisor uses on-behalf-of authorization,
so the calling user's identity propagates to sub-agents, which is how per-user permission
checks work end to end. For stateful agents, keep short- and long-term memory and
conversation threading in a store such as Lakebase, keyed by thread and conversation ids.

## Security checklist

- No secrets in environment variables (use UC connections).
- All SQL parameterized or safely escaped; input validation on every tool parameter.
- Rate limiting on Genie; connection-pool limits to prevent resource exhaustion.
- Async audit never blocks the tool response.
- Structured logging with `request_id`; retry with jitter to avoid thundering herd.
- Health check validates all dependencies.
- Tokens never logged, even in error messages.

## Related

- [Runtime Config Patterns](runtime-config-patterns.md), hot-deployable tool-access matrices and roles
- [Identity: Production Federation](../identity/federation-production.md), how a governed token reaches the server
- [Identity: Authorization](../identity/authorization.md), scopes and UC grants
- [Observability: App Observability](../observability/app-observability.md), the trace + audit implementation

## Public References

- [Author a Databricks agent](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent)
- [HTTP connections (query federation)](https://docs.databricks.com/aws/en/query-federation/http)
- [Unity Catalog privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/privileges)
