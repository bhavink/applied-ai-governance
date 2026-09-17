# Service Identity and Audit Architecture

> A Databricks AI application usually spans several services (Genie, Vector Search, UC
> Functions, custom MCP, Agent Bricks, external MCP). Each has its own identity model: some
> run as the user (OBO), some as the app service principal (M2M). This doc maps which identity
> each service honors, and shows how to build the audit trail that the platform does not build
> for you: the join from a human to the SP-executed query they caused. For the token mechanics
> that put an identity in front of a service, see [Production Federation](federation-production.md);
> for the proxy header details, see [Proxy Architecture](proxy-architecture.md).

## 1. Why this is hard

- **Identity fragmentation.** `system.access.audit` records the SQL session identity. On an
  M2M path that is the SP, not the human who triggered it, so the human is invisible in the
  data-plane audit log.
- **Scope overexposure.** OAuth integrations default to broad scopes; a token then reaches
  every workspace service, not just the one the app needs.
- **No built-in join.** The application plane (MLflow traces) and the data plane
  (`system.access.audit`) are separate systems with no platform-provided foreign key. Teams
  build the correlation themselves.
- **Extensibility.** New services (Lakebase, new MCP servers, new agent frameworks) must fit
  the same identity and audit pattern rather than each getting an ad hoc solution.

## 2. The three identity models

| Model | Who executes | User identity source | `current_user()` | UC audit shows |
|---|---|---|---|---|
| True OBO | the user's token | OAuth token | user email | user email |
| Proxy identity + M2M | the app SP | `X-Forwarded-Email` (proxy-injected) | SP UUID | SP UUID |
| Pure M2M | the app SP | not involved | SP UUID | SP UUID |

The proxy injects `X-Forwarded-Email` (high trust, unforgeable), `X-Forwarded-User`
(`{user_id}@{workspace_id}`), and `X-Forwarded-Access-Token`. With Apps user authorization
enabled, that forwarded token can be a real OBO JWT carrying service scopes (`sql`, `serving`);
without it, it is a minimal OIDC token that only proves identity.

## 3. Per-service identity map

| Service | Identity model | `current_user()` | Row filters fire as | UC audit identity |
|---|---|---|---|---|
| Genie (Conversation API) | True OBO | user email | user (Genie service context for group checks) | user |
| AI/BI Dashboard (run-as-viewer) | True OBO | viewer email | viewer | viewer |
| AI/BI Dashboard (run-as-owner) | delegated | owner email | owner | owner |
| Agent Bricks / Model Serving | True OBO (token propagated to sub-agents) | user email | user | user |
| SQL Warehouse (user token) | True OBO | user email | user | user |
| SQL Warehouse (SP token) | Pure M2M | SP UUID | SP | SP UUID |
| Custom MCP (Databricks Apps) | Proxy + M2M, or True OBO with user authorization + `sql` | SP UUID (M2M) or user email (OBO SQL) | manual WHERE (M2M) or automatic (OBO SQL) | SP UUID or user email |
| UC Functions (via M2M SQL) | Pure M2M | SP UUID | SP | SP UUID |
| UC Functions (via Genie OBO) | True OBO | user email | user | user |
| Vector Search | Pure M2M | not applicable | not applicable | SP UUID |
| Foundation Model API | M2M or OBO | not relevant to inference | not applicable | caller |
| External MCP (shared bearer, UC HTTP) | M2M at proxy; shared key externally | not applicable | not applicable | caller at proxy; `USE CONNECTION` is the boundary |
| External MCP (per-user OAuth, UC HTTP) | OBO at proxy; user OAuth externally | not applicable | not applicable | user at proxy; `USE CONNECTION` is the boundary |
| Custom MCP to custom MCP (chained) | Proxy + M2M | SP UUID | manual | SP UUID |

### Audit gap by model

| Identity model | Does UC audit capture the human? | Application-plane audit needed? |
|---|---|---|
| True OBO | Yes, automatically | Optional, for enrichment |
| Proxy + M2M | No, shows SP UUID (closable: OBO SQL via user authorization records the human) | Required on the M2M path; not required on OBO SQL |
| Pure M2M | No, shows SP UUID | Required if per-user attribution matters |
| Delegated | Yes, but shows the owner, not the end user | Depends on the use case |
| External MCP | Not applicable (external service) | Required; the Databricks audit shows the proxy call, not the external action |

## 4. Scopes, in brief

A user token should carry the minimum scopes for what it must do: `openid email profile
offline_access` to prove identity, plus `genie` (and `dashboards.genie` on Azure) for Genie,
`model-serving` for Agent Bricks / Model Serving, `unity-catalog` for External MCP over UC
HTTP connections, and `sql` for OBO SQL. Prefer configuring `sql` through the Apps user
authorization panel so the forwarded token is a real OBO JWT. Avoid a catch-all scope. The
full table with gotchas lives in [OAuth Scopes](oauth-scopes-reference.md).

## 5. Builder considerations

These are the sharp edges worth knowing before you design the audit posture. They are framed
as choices, not complaints.

- **M2M loses the human in the data plane, and OBO SQL closes it.** On a pure M2M path,
  `system.access.audit` records the SP. If you configure user authorization and the `sql`
  scope, OBO SQL makes `current_user()` the human and UC audit records the human directly,
  which removes the need for a time-window join. Where OBO SQL is not available, use the
  application-plane audit table in section 7.
- **There is no platform join between MLflow traces and UC audit.** They are separate system
  tables with no foreign key. Correlate on SP UUID plus a time window (approximate) or on a
  shared `trace_id`/`request_id` you propagate (precise).
- **`is_member()` evaluates the SQL execution identity.** Under Genie or Agent Bricks OBO, a
  row filter using `is_member()` checks the service's groups, not the caller's, so it returns
  the wrong result. Use `current_user()` plus an allowlist table, or account-group checks,
  and re-test under OBO SQL where the execution identity is the real user.
- **External MCP over UC HTTP requires the `unity-catalog` scope.** Without it the proxy
  returns a 403 before it even checks `USE CONNECTION`.
- **A connection owner has implicit `USE CONNECTION`.** When auditing who can invoke an
  External MCP tool, check both explicit grants and connection ownership, because ownership
  does not appear in `SHOW GRANTS`.
- **Changing OAuth scopes may require re-authorization.** Existing refresh tokens keep their
  original scopes; picking up new scopes can require a fresh authorization flow. Plan scope
  changes deliberately rather than as a hot edit.

## 6. Confused-deputy prevention: one SP per capability boundary

A confused deputy is a trusted principal (the app SP) tricked into using its authority for an
unauthorized caller. The defense is isolation: **one service principal per capability
boundary, not one per application.** An agent that does read-only analysis and an agent that
submits approvals must have different SPs, so a vulnerability in one cannot exercise the
other's privileges.

| App / component | SP | Read | Write | Why separate |
|---|---|---|---|---|
| Front-end app | SP-A | Genie (OBO), Vector Search, UC Functions, FM API | none | a front end should never hold direct write access |
| Custom MCP server | SP-B | specific data tables | one approval table (INSERT only) | tools need targeted write; the front end does not |
| External-client MCP | SP-C | same reads as SP-B | same writes as SP-B | different auth setting and lifecycle; isolate credentials |
| Agent Bricks supervisor | platform-managed | sub-agents inherit the user token (OBO) | through sub-agent tools only | supervisor SP is managed; access equals the user's |

Grant scoping follows the boundary: the front-end SP gets `USE CATALOG`/`USE SCHEMA`,
`SELECT` on shared tables, and `EXECUTE` on functions, but no `MODIFY`; the MCP SP adds
`MODIFY` only on the one approval table; every MCP SP that writes audit gets `MODIFY` on the
audit table. Anti-patterns to avoid: sharing one client id/secret across apps, granting
`ALL PRIVILEGES` on a catalog, using one SP for read and write tools, and adding an MCP SP to
admin groups (which bypasses row filters and masks). Verify isolation with `SHOW GRANTS TO`
each SP; the grant sets should be minimal and non-overlapping.

What isolation buys you: a compromised front end cannot write; tool-injection blast radius is
confined to one SP's grants; revoking one client does not disturb the others; credential
rotation is per app; and different SP UUIDs in `system.access.audit` give immediate
attribution to the app that ran a query.

## 7. What the platform provides, and the audit table you add

### System tables

| Table | Records | Identity field |
|---|---|---|
| `system.access.audit` | UC operations, SQL, API calls, app lifecycle | `user_identity.email` (executing identity) |
| `system.access.table_lineage` | table-level data flow | source/target metadata |
| `system.access.column_lineage` | column-level data flow | source/target column names (PII propagation) |
| `system.information_schema.column_masks` | applied masks | verify masks on sensitive columns |
| `system.billing.usage` | DBU consumption and cost | `identity_metadata` |
| `mlflow` traces | agent conversation spans | application-plane record of decisions and tool calls |

The key limitation: `system.access.audit` records the executing identity only. On an M2M path
that is the SP UUID; there is no `requested_by` or `on_behalf_of` field. That is exactly the
gap the application-plane audit table fills.

### MLflow tracing

Set `caller.email` and the SP id as span tags, use the `TOOL` span type for tool calls, and
store `request_id`/`trace_id` so traces join to your audit table precisely. Trace tags are a
convention, not enforced, so make them automatic with a decorator rather than relying on each
tool to remember.

### The application-plane audit table

Record who (human) asked for what (tool + args) via which agent (SP), append-only, joinable to
`system.access.audit` on SP + time window and to traces on `trace_id`, and service-agnostic so
new services add rows rather than columns.

```sql
CREATE TABLE catalog.audit.tool_invocations (
  caller_email    STRING NOT NULL,   -- X-Forwarded-Email, proxy-verified human
  caller_user_id  STRING,            -- X-Forwarded-User
  app_sp_id       STRING NOT NULL,   -- the SP that ran SQL
  app_name        STRING NOT NULL,
  service_type    STRING NOT NULL,   -- custom_mcp | uc_function | external_mcp | agent_bricks | genie
  tool_name       STRING NOT NULL,
  tool_args_hash  STRING,            -- SHA-256 of canonical args
  tool_args_safe  STRING,            -- sanitized JSON (secrets/PII redacted)
  result_status   STRING NOT NULL,   -- success | error | denied | timeout
  error_message   STRING,
  trace_id        STRING,            -- precise join to traces
  request_id      STRING NOT NULL,
  event_time      TIMESTAMP NOT NULL,
  duration_ms     LONG
)
USING DELTA
TBLPROPERTIES ('delta.enableChangeDataFeed' = 'true');
```

Write it from a decorator so tool logic never changes, and so an audit write can never break a
tool:

```python
def audited(service_type: str = "custom_mcp"):
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            caller = _caller_email()          # from X-Forwarded-Email
            request_id = str(uuid.uuid4())
            start = time.monotonic()
            try:
                result = func(*args, **kwargs)
                status = "error" if isinstance(result, dict) and "error" in result else "success"
                _write_audit(caller, service_type, func.__name__, kwargs, status,
                             request_id, int((time.monotonic()-start)*1000))
                return result
            except Exception as e:
                _write_audit(caller, service_type, func.__name__, kwargs, "error",
                             request_id, int((time.monotonic()-start)*1000), error=str(e))
                raise
        return wrapper
    return decorator
```

The audit write should redact sensitive keys, hash canonical args, and swallow its own
exceptions so a failed INSERT never surfaces to the user.

### Chain-of-custody query

Join your table (the human) to the data plane (the SP-executed query):

```sql
WITH app_events AS (
  SELECT request_id, caller_email, tool_name, tool_args_safe, result_status, trace_id,
         app_sp_id, event_time,
         event_time - INTERVAL 2 SECONDS  AS window_start,
         event_time + INTERVAL 30 SECONDS AS window_end
  FROM catalog.audit.tool_invocations
  WHERE event_time > current_timestamp() - INTERVAL 24 HOURS
)
SELECT a.caller_email AS human, a.tool_name AS tool, u.action_name AS uc_operation,
       u.user_identity.email AS uc_identity, a.event_time AS tool_time, u.event_time AS uc_time
FROM app_events a
LEFT JOIN system.access.audit u
  ON u.user_identity.email = a.app_sp_id
  AND u.event_time BETWEEN a.window_start AND a.window_end
  AND u.service_name IN ('unityCatalog','sqlStatements','databricksSql')
ORDER BY a.event_time DESC;
```

Unity Catalog only knows the SP ran the queries; your audit table proves which human triggered
each one. Alert views over the same table catch broken auth (empty caller email), high-frequency
callers, write operations, and error-rate spikes.

## 8. Honest limitations

- The time-window join is approximate: two users hitting the same tool via the same SP within
  the window can be misattributed. Use `trace_id`, or better, OBO SQL so UC records the human.
- The audit table needs SP `MODIFY`; keep it a dedicated audit table, not production data.
- Trace tags are convention; the decorator makes them automatic, and code review catches a tool
  that lacks it.
- External MCP audit is one-sided: you record that the human invoked the tool, not what the
  external service did. Per-user OAuth connections leave an external audit tied to the user;
  shared bearer connections do not.

## Related

- [Authorization](authorization.md), the token patterns and UC enforcement model
- [Production Federation](federation-production.md), how a governed token reaches a service
- [Proxy Architecture](proxy-architecture.md), header injection and the two-proxy problem
- [OAuth Scopes](oauth-scopes-reference.md), the full scope table and gotchas
- [Observability: Audit Reference](../observability/audit-reference.md), system-table audit queries
- [Observability: App Observability](../observability/app-observability.md), the trace and audit implementation

## Public References

- [System tables: audit logs](https://docs.databricks.com/aws/en/admin/system-tables/audit-logs)
- [OAuth user-to-machine](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m)
- [Unity Catalog privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/)
- [Author a Databricks agent](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent)
- [MLflow tracing](https://docs.databricks.com/aws/en/mlflow3/genai/tracing/)
