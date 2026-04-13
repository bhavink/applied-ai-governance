# OAuth Scopes — Governance Reference

> **TL;DR**: Scopes are the **capability ceiling** — they gate which API endpoints a token can call. UC grants are the **actual authorization** — they determine what data within those endpoints the token can access. Both layers are required for true least-privilege access. There are 36 workspace-level and 9 account-level granular scopes.

---

## The Governance Principle

OAuth scopes and UC grants serve different functions. Neither replaces the other.

| Layer | Question it answers | Granularity | Example |
|---|---|---|---|
| **OAuth scopes** | Can this token call this API endpoint? | Per-product-area (e.g., `sql`, `genie`, `unity-catalog`) | Token with `sql` scope can call Statement Execution API |
| **UC grants** | Can this identity access this data? | Per-object (table, function, connection) | `GRANT SELECT ON TABLE` to a specific SP |

A token with `sql` scope but no `GRANT SELECT` → API call succeeds, query returns 0 rows.
A token without `sql` scope but with `GRANT SELECT` → API call fails with 403.

---

## AI App Scope Selection

| Use case | Scopes needed |
|---|---|
| Identity-only MCP (M2M for all data) | `openid email profile offline_access` — no product scopes |
| Genie OBO | + `dashboards.genie` + `genie` |
| Agent Bricks / Model Serving OBO | + `model-serving` |
| External MCP (UC HTTP) | + `unity-catalog` |
| Direct SQL OBO (via UI User Authorization) | + `sql` |
| Claude Code external client | `all-apis offline_access` (U2M PKCE) |
| Full-featured app | All above + `all-apis` |

**Principle**: Request only what the app needs. `all-apis` is convenient but grants access to every API endpoint.

---

## Write-Risk Classification (Blast-Radius Tiers)

Every scope except `query-history` allows mutations. There are no read-only scope variants. This makes scope selection a **blunt instrument** — but still valuable as a second fence beyond UC grants.

| Tier | Scopes | Why they're critical |
|---|---|---|
| **Tier 1 — Critical** | `unity-catalog`, `sql`, `clusters`, `workspace`, `secrets`, `settings`, `authentication`, `provisioning` | Data destruction, credential theft, security posture changes, workspace deletion |
| **Tier 2 — High** | `jobs`, `pipelines`, `apps`, `sharing`, `files`, `model-serving`, `scim`, `postgres`, `networking` | Arbitrary code execution, data exfiltration via sharing, identity manipulation |
| **Tier 3 — Medium** | `mlflow`, `dashboards`, `genie`, `vector-search`, `alerts`, `cleanrooms`, `knowledge-assistants` | Limited blast radius per scope |
| **Tier 4 — Low** | `query-history` (read-only), `access-management`, `identity`, `dataclassification` | Read-heavy, minimal write risk |

**LPA recommendation**: Replace `all-apis` with the union of only the granular scopes each SP actually needs. The blocked write operations are the ones that would let a compromised token do lateral damage.

---

## SQL Identity Functions

These determine identity in row filters, column masks, and RLS policies:

| Function | Returns | Key behavior |
|---|---|---|
| `session_user()` | Connected user | Recommended since Runtime 14.1 |
| `current_user()` | Executing user | SP UUID for M2M; human email for OBO |
| `is_member(group)` | Boolean | Checks **workspace-level groups only** — account-level groups return false |
| `is_account_group_member(group)` | Boolean | Checks account-level groups |

**Genie OBO gotcha**: `is_member()` under Genie OBO evaluates the Genie service context, not the human's groups. Use `current_user()` + allowlist table lookup instead.

---

## Scope Gotchas

| Issue | Governance impact |
|---|---|
| `sql` scope: CLI vs UI | CLI `custom-app-integration update` does NOT produce real OBO JWTs. UI User Authorization does. |
| `genie` scope hidden on Azure | Account console UI doesn't show it. Add via CLI — without it, Genie API returns 403. |
| `unity-catalog` scope undocumented | Required by External MCP proxy to verify `USE CONNECTION`. Missing = 403. |
| Scope changes require re-auth | Adding scopes doesn't propagate to existing refresh tokens. Users must re-authorize. |
| `all-apis` is not a superset | Some features also check their specific scope. Include both when in doubt. |
| `postgres` = Lakebase management only | Database access uses separate `generate-database-credential` tokens — two distinct auth layers. |

---

## Related

- [Authorization](authorization.md) — Token patterns and scope vs UC grant interplay
- [Proxy Architecture](proxy-architecture.md) — How scopes flow through the Apps proxy

For the complete 45-scope reference table with operation counts, account vs workspace endpoint details, and LPA SP examples, see the [fieldkit OAuth scopes reference](https://github.com/bhavink/fieldkit).
