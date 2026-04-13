# Authorization (AuthZ)

> AuthZ is where Databricks plays. Unity Catalog is the authorization engine for all AI services.

## The Three Token Patterns

Once a user or service authenticates (AuthN), the next question is: what identity does Databricks see when it evaluates permissions? This depends on the token pattern.

### OBO (On-Behalf-Of)

The app forwards the user's own token. Databricks sees the human.

- `current_user()` returns the human's email
- UC row filters and column masks fire as that individual
- Audit trail records the human's identity
- **When to use**: Internal apps where users have Databricks workspace accounts. Streamlit dashboards, interactive analytics, agent tools.

The Databricks Apps proxy handles this automatically. When a user accesses a Databricks App, the proxy authenticates them via the workspace IdP and injects identity headers including `X-Forwarded-Email` and `X-Forwarded-Access-Token`. **Important**: `X-Forwarded-Access-Token` is a minimal OIDC identity token — it does NOT carry `sql` scope, regardless of the OAuth integration's `user_authorized_scopes` configuration. Use it for Genie and Model Serving OBO calls; use M2M (`WorkspaceClient()`) for SQL operations with identity from `X-Forwarded-Email`. See [Proxy Architecture](proxy-architecture.md) for the complete header reference.

Reference: [Databricks Apps authentication](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth), [App key concepts](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/key-concepts)

### M2M (Machine-to-Machine)

The app uses its own service principal credentials. Databricks sees the SP.

- `current_user()` returns the SP's application UUID
- UC row filters fire as the SP identity (all users of the app see the same data)
- Audit trail records the SP, not the human who triggered the action
- **When to use**: Background jobs, pipelines, CI/CD, scheduled tasks, health checks, audit writes. Anything where no user is present or per-user distinction doesn't matter.

`WorkspaceClient()` with no arguments picks up the SP credentials automatically from the Databricks Apps environment.

Reference: [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m), [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)

### Federation (Token Exchange)

An external app exchanges an IdP token for a Databricks SP token. Users don't have Databricks accounts.

- External user authenticates with their own IdP (Okta, Entra, Auth0)
- The app exchanges the IdP JWT for a scoped Databricks SP token via RFC 8693
- UC sees the role-based SP, not the individual
- App-level audit captures the human identity from the IdP JWT
- **When to use**: Partner portals, customer-facing apps, multi-tenant SaaS. Users authenticate via their own identity system.

See [Federation Exchange](federation.md) for the full pattern.

### U2M from External Apps

For external apps where the user is already a Databricks user, see [U2M from External Apps](u2m-external-obo.md) for a pattern that preserves `current_user()` = human email without Federation. This covers cases like Cloudflare Workers, AWS Lambda, or any backend outside the Databricks Apps proxy where you still want per-user identity propagation.

### Choosing the Right Pattern

| Question | Answer |
|----------|--------|
| Does the user have a Databricks account? | Yes: OBO. No: Federation. |
| Is there a human in the loop? | Yes: OBO or Federation. No: M2M. |
| Do you need per-user row filters in UC? | Yes: OBO (individual). Federation uses group-based `is_member()`. |
| Is this a background job or pipeline? | M2M. |
| Both internal and external users? | OBO for internal + Federation for external. Same UC governance, same MCP tools. |

Most production apps combine OBO + M2M: user-facing calls use OBO (identity propagation), background tasks use M2M (service credentials).

## OAuth Scopes

Scopes control what the **token** can do. They are a capability ceiling, not an authorization system.

| Scope | What it gates |
|-------|--------------|
| `sql` | SQL warehouse access |
| `genie` | Genie Conversation API |
| `serving` | Model Serving endpoints |
| `files.files` | File and directory access |
| `apps` | Calling other Databricks Apps |

**The principle**: request only what the app needs. Never use `all-apis` in production.

**Scopes vs. UC grants**: Scopes limit which API endpoints a token can reach. UC grants limit which data a given identity can access within those endpoints. Both are required. Neither replaces the other.

Configure scopes via the Databricks Apps UI "User authorization" panel for OBO tokens.

For the complete reference of all 45 scopes, blast-radius tiers, SQL identity functions, and known gotchas, see [OAuth Scopes Reference](oauth-scopes-reference.md).

Reference: [App resources and authorization](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/resources)

## Service Principals

Service principals are non-human identities used by apps, jobs, and automated systems.

### Account-Level vs. Workspace-Level

| | Account-Level SP | Workspace-Level SP |
|---|---|---|
| Created in | Account Console | Workspace Admin Console |
| Visible across workspaces | Yes (can be assigned to multiple) | No (single workspace) |
| UC grants | Use the Application UUID | Use the Application UUID |
| `current_user()` returns | Application UUID | Application UUID |
| Recommendation | **Use this** for all production workloads | Legacy; avoid for new work |

### Two Identifiers, Don't Confuse Them

Every SP has:
- **Application UUID** (e.g., `bf2278a6-...`): Used in UC grants (`GRANT SELECT TO '<uuid>'`) and returned by `current_user()` in SQL
- **Numeric SCIM user ID** (e.g., `147918915240187`): Used for group membership operations via the SCIM API

### Group Membership

- `is_member('group_name')` checks **workspace-level group membership only**
- Account-level groups are NOT visible to `is_member()`
- If you sync groups from your IdP at the account level, create parallel workspace-level groups or use `current_user()` with a lookup table instead

This is the single most common silent failure in row filters and column masks: the SP is in the right account-level group, but `is_member()` returns false because it only checks workspace groups.

**Second failure mode (Genie OBO)**: Even when groups are at the workspace level, `is_member()` under Genie OBO evaluates the session user's group membership, which resolves to the Genie service context — not the human's workspace groups. This means `is_member('executives')` in a row filter returns false under Genie OBO even if the human is in the `executives` group. **Workaround**: Use `current_user()` with an allowlist table lookup instead of `is_member()`:

```sql
-- Broken under Genie OBO:
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(is_member('executives'), val, NULL);

-- Correct:
CREATE FUNCTION mask_quota(val DECIMAL) RETURNS DECIMAL
  RETURN IF(current_user() IN (SELECT email FROM quota_viewers), val, NULL);
```

## The UC Governance Model

Unity Catalog is the single authorization engine for all Databricks services. It governs:

| What | How |
|------|-----|
| Data access | `GRANT SELECT/MODIFY` on tables, views, volumes |
| Function execution | `GRANT EXECUTE` on UC functions |
| External connections | `GRANT USE CONNECTION` on UC connections |
| Row-level security | Row filter functions (transparent WHERE injection) |
| Column-level security | Column mask functions (transparent value transformation) |
| Data classification | Governed tags + ABAC policies |

The critical property: **UC enforcement fires at the SQL engine level.** It doesn't matter which AI service issues the query (Genie, Agent Bricks, custom MCP, notebook, BI tool). The same row filters, column masks, and grants apply. Applications cannot bypass UC governance.

Reference: [Unity Catalog](https://docs.databricks.com/en/data-governance/unity-catalog/index.html), [Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control), [ABAC tutorial](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/tutorial)

## Related

- [Proxy Architecture](proxy-architecture.md) — complete header reference, two-proxy problem, `authorization: disabled`
- [OAuth Scopes Reference](oauth-scopes-reference.md) — all 45 scopes, LPA blast-radius tiers, SQL identity functions
- [Cloud Auth Patterns](cloud-auth-patterns.md) — Entra ID, Azure Managed Identity, Okta token federation
- [Federation Exchange](federation.md) — external users without Databricks accounts
- [U2M from External Apps](u2m-external-obo.md) — Databricks users from external SPAs

## Building AI Apps: Key Patterns

If you're building apps on Databricks (Streamlit, Dash, Flask, or custom MCP servers), these patterns apply regardless of framework:

| Pattern | How |
|---------|-----|
| Get the user's identity | Read `X-Forwarded-Access-Token` from the Apps proxy (OBO) |
| Get the app's SP credentials | `WorkspaceClient()` with no arguments (M2M) |
| Execute SQL as the user | Use the OBO token with `sql` scope configured via UI |
| Execute SQL as the app | Use the SP credentials (M2M path) |
| Call Genie as the user | Use the OBO token with `genie` scope |
| Call external APIs | Use UC connections with `GRANT USE CONNECTION` |
| Audit who did what | Platform audit captures the SQL identity; app audit captures the human behind the SP |

Reference: [Authoring agents](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent), [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication), [App key concepts](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/key-concepts)
