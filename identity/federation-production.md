# External App to Databricks: Production Federation (RFC 8693)

> **What this is**: the decision framework and production hardening for an external app,
> hosted outside Databricks and using its own IdP, that needs the end user's identity
> propagated to Databricks so Unity Catalog honors that user's permissions. It sits above
> the three scenario docs ([per-user](byoidp-peruser-federation.md),
> [role-based](federation.md), [OBO](u2m-external-obo.md)) and tells you which one you need.

> **The one hard rule**: a service principal credential cannot produce per-user identity.
> Databricks has no service-principal-to-user impersonation. To make `current_user()`
> resolve to the human, the app must present a **user-scoped token**, obtained either by the
> user logging in (U2M OAuth) or by exchanging the user's own IdP JWT (RFC 8693). SP
> credentials alone always resolve to the SP.

## The three identity paths

| Path | Where it runs | `current_user()` | UC granularity | Token lifecycle owner |
|---|---|---|---|---|
| **A** per-user RFC 8693 exchange | anywhere outside Databricks | the **human** | individual | you (light, see below) |
| **B** role-based RFC 8693 exchange | anywhere outside Databricks | a **role SP** | group / role | you (SP tokens) |
| **C** Databricks Apps proxy OBO | **on** Databricks Apps | the **human** | individual | the platform |

**Pick a path:**

1. Hosted on Databricks Apps with workspace SSO login? Use **Path C**: the Apps authorizing
   proxy mints and refreshes a per-user token and injects it as `X-Forwarded-Access-Token`.
   No token handling in your code. Only available inside Databricks Apps. See
   [Databricks Apps Proxy Architecture](proxy-architecture.md).
2. Hosted outside, users can be SCIM-synced, and UC must enforce per-individual access? Use
   **Path A**. Full how-to in [Per-User BYO-IdP Federation](byoidp-peruser-federation.md).
3. Hosted outside, role-level governance is sufficient (or users cannot be provisioned)? Use
   **Path B**. Per-user attribution then lives in your application audit, not in UC. Recipe
   in [Federation](federation.md) and the [Federation blueprint](federation-implementation-blueprint.md).
4. Mixed? Use a **hybrid**: per-user tokens for data reads that need individual RLS, an app
   SP for infrastructure calls.

## Path A: per-user exchange (`current_user()` = human)

**Prerequisites**

1. Users **SCIM-synced** to the account. Federation *maps* an identity, it does not create
   one; a first exchange for an unprovisioned user returns `401`.
2. An **account-wide federation policy** whose `issuer`, `audience`, and `subject_claim`
   match the IdP tokens. Map on an **immutable** claim (a stable `sub`), not on `email`.
3. Any groups used in row filters are SCIM-synced at the **account** level.

**The exchange (no `client_id`):**

```
POST https://<workspace-host>/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<END_USER_IDP_JWT>
&subject_token_type=urn:ietf:params:oauth:token-type:jwt
&scope=all-apis
```

Including a `client_id` selects a service principal and turns this into Path B, losing
per-user RLS. Omit it for per-user identity.

**Per-user row-level security:** the token establishes *who*; a UC row filter or dynamic
view enforces access. Gate on `current_user()`. Note that `is_member('group')` checks only
**workspace-level** groups and returns FALSE when groups are account-level (the recommended
SCIM setup); use a lookup table keyed on `current_user()` instead, or mirror groups to the
workspace. See [row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/).

## Path B: role-based exchange (`current_user()` = role SP)

Map many external users to a few role service principals. Same exchange **with** the role
SP's `client_id`:

```
grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<IDP_JWT>
&subject_token_type=urn:ietf:params:oauth:token-type:jwt
&client_id=<ROLE_SP_APPLICATION_ID>
&scope=all-apis
```

Authorization comes from the SP's UC grants and group membership; attribution comes from the
JWT claims, which the app preserves in its own audit table because UC sees only the SP; RLS
uses `is_member('<role-group>')`. This path needs **no per-user token tracking**, which is
why it scales cheaply. The trade is the loss of per-user UC enforcement. Full recipe in the
[Federation blueprint](federation-implementation-blueprint.md).

## Token lifecycle at scale

A per-user design does not require tracking each user's token or scheduling refreshes, if
you exchange on demand.

| Token | TTL | Refreshable | Refresh owner |
|---|---|---|---|
| user's IdP JWT | ~1 hour | yes (IdP refresh-token flow) | the IdP + the app session |
| exchanged Databricks token | ~1 hour | **no** (re-exchange) | treat as disposable |

- On each request you already hold the user's live IdP token; exchange it, use it, discard.
- The IdP owns user-token refresh; you build no scheduler.
- Optional: cache the exchanged token per user in memory, TTL ~50 min, keyed on the
  immutable `sub`. A bounded in-memory cache, never a persistent store.
- Databricks copies the IdP JWT `exp` verbatim onto the issued token, so always exchange a
  **fresh** IdP token, especially before a long operation.

## Production hardening (both paths)

- **JWKS**: verify the IdP JWT signature (RS256/ES256); cache keys by `kid` with a bounded
  TTL; re-fetch on an unknown `kid` to handle rotation; fail closed. HS256 with no JWKS
  cannot be used for per-user federation; fall back to U2M SSO.
- **Retry**: retry only `429/500/502/503/504` with exponential backoff plus jitter, capped.
  `400/401/403` are configuration errors; surface them.
- **Rate limits**: `/oidc/v1/token` is rate limited per account (a short exchange cache
  keeps you under it); Genie Agents allows about 5 queries per minute per workspace, so enforce a
  client-side sliding-window limiter and return a retry hint.
- **Threat model**: rotate IdP signing keys and pin the JWKS URI in the policy; verify
  `iss`/`aud`/`sub` exactly; keep any M2M secret server-side; use short TTLs and
  server-side exchange so the browser never holds Databricks credentials; restrict audit
  writes to a single app SP.
- **Account issuer cap**: an account allows a limited number of federation issuers. Do not
  register one per customer tenant; consolidate per IdP platform or via a broker IdP, and
  plan a rotation path before reaching the cap.
- **Audit correlation (Path B)**: `system.access.audit` records the SP, not the human.
  Preserve the external identity and a correlation id in your app audit, then join to the
  system audit on time window + SP + workspace to attribute a query back to the individual.
  Under Path A this is unnecessary; UC records the human directly.
- **Multi-hop propagation**: one exchanged token works across services within a request as
  long as its scope covers them; you do not re-exchange per service. Across component hops
  (app to Databricks App to MCP server) the identity survives only if the token is
  **forwarded** on each hop. A dropped token silently falls back to the component's own
  identity. See [Databricks Apps Proxy Architecture](proxy-architecture.md).

## Service notes

| Service | Endpoint | Scope | Identity honored |
|---|---|---|---|
| SQL Statement Execution | `/api/2.0/sql/statements` | `sql` | token identity |
| Genie Conversation API | `/api/2.0/genie/spaces/{id}/...` | `sql` + `genie` | token identity |
| Vector Search | SDK / REST | `vector-search` | token identity |
| Model Serving / FMAPI | `/serving-endpoints/{id}/invocations` | `serving` | token identity |

**There is no "Genie Agents-only" token exchange.** Genie Agents executes SQL against its backing
warehouse, so a Genie Agent caller needs `sql` in addition to `genie`; the federation policy
authorizes the exchange, not which service the token may reach; and scope narrowing can be
rejected by the Databricks Apps proxy. Restrict a caller to Genie Agents via **UC grants** on the
Genie Agent and its underlying tables, with scope hardening as defense in depth. See the
[Genie Conversation API](https://docs.databricks.com/aws/en/genie/conversation-api) and
[OAuth Scopes](oauth-scopes-reference.md).

## Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Exchange returns an SP token, RLS shows all rows | `client_id` was included | Omit `client_id` for per-user (account-wide) federation |
| `401` on first exchange for a user | SCIM sync not complete; the user does not exist yet | Complete SCIM sync before the first exchange |
| Access silently breaks for a user over time | mapped on `email`, which changed upstream | Map on an immutable claim |
| Token expires mid-request | Databricks copies the JWT `exp` verbatim | Exchange a fresh IdP token |
| `is_member()` filter returns no rows for anyone | groups are account-level; `is_member()` checks workspace-level only | Use a lookup table keyed on `current_user()`, or mirror groups to the workspace |
| A downstream hop sees the wrong identity | the token was not forwarded on the hop | Forward the token explicitly on every hop |

## Replicating Databricks Apps OBO outside Databricks

Inside Databricks Apps, "user authorization" runs an authorizing proxy that performs the
OAuth flow against the workspace SSO, mints a per-user token, injects it as
`X-Forwarded-Access-Token`, and manages refresh for you. Outside Databricks Apps that proxy
does not exist and cannot be reproduced from SP credentials. The off-platform equivalent is
Path A: exchange the user's own IdP token for a per-user Databricks token, and own the light
lifecycle above. The Genie Agents SDK and Conversation API have no OBO mode of their own; they act
as whatever token you provide.

## Related

- [Authorization](authorization.md), the three token patterns and the UC enforcement model
- [Per-User BYO-IdP Federation](byoidp-peruser-federation.md), Path A how-to, JWKS decision, no-JWKS fallback
- [Federation](federation.md), Path B overview, bridging external IdPs to Databricks
- [Federation blueprint](federation-implementation-blueprint.md), Path B step-by-step recipe and error catalog
- [U2M from External Apps](u2m-external-obo.md), OBO for users already provisioned in the workspace
- [Databricks Apps Proxy Architecture](proxy-architecture.md), Path C token propagation across hops
- [OAuth Scopes](oauth-scopes-reference.md), scopes required per downstream API
- [Cloud Auth Patterns](cloud-auth-patterns.md), Entra, Okta, and GCP WIF specifics

## Presentations

- [Cross-IdP Federation](https://bhavink.github.io/applied-ai-governance/presentations/cross-idp-federation.html): propagating an external end-user identity from an app and its IdP through Unity Catalog enforcement.

## Public References

- [OAuth token federation (overview)](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation)
- [Configure a federation policy](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation-policy)
- [Authenticate with an identity provider token (exchange)](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-federation-exchange)
- [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/)
- [Genie Conversation API](https://docs.databricks.com/aws/en/genie/conversation-api)
