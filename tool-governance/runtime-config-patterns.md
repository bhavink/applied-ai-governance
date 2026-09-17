# Runtime Config Patterns: Decoupling Policy from Code

> **Problem**: role mappings, tool-access matrices, and persona/UI metadata get hardcoded
> across several layers (front end, edge function, server). Adding a role or changing tool
> access then means code changes and redeploys across two or three services.
>
> **Goal**: a single source of truth for runtime policy that is hot-deployable in seconds
> rather than deploys, provider-agnostic, and versioned with rollback.

## Design principles

1. **Config is an API contract.** Consumers fetch it from a well-defined endpoint; where it
   lives is an implementation detail.
2. **Read-only at the edge.** Front ends and edge functions only read; writes go through an
   admin path with validation.
3. **Cache with fallback.** Every consumer caches last-known-good. If the source is down,
   stale config beats no config.
4. **Schema-versioned.** Every response carries a version so consumers can detect stale cache
   and request a specific version.
5. **No secrets in config.** SP credentials, client secrets, and tokens are infrastructure,
   not config; they stay in a secret manager or environment.
6. **Auditable.** Every change is attributed (who, when, what changed).

## What goes where

| Category | Examples | Where |
|---|---|---|
| Runtime policy | tool-access matrix, roles, persona metadata, UI labels | config store (hot-deployable) |
| Infrastructure IDs | warehouse id, Genie space id, endpoint names | env vars (deploy-time) |
| Credentials | SP client secrets, API keys, bearer tokens | secret manager / env |
| Business logic | tool implementations, SQL, API calls | code (version-controlled) |

## Config API contract

`GET /config` returns the full runtime config; consumers cache it and use `version` for
freshness. `GET /config?version=N` returns a specific version for rollback verification.
`HEAD /config` returns only headers with `X-Config-Version`, a cheap freshness check.

```json
{
  "version": 7,
  "updated_at": "2026-03-17T19:30:00Z",
  "updated_by": "admin@example.com",
  "roles": [
    { "role": "west_sales", "display_name": "West Territory Lead", "group": "west_sales", "active": true }
  ],
  "tools": {
    "check_identity": { "label": "Identity", "category": "Identity", "needs_input": false,
                        "tip": "Shows your IdP identity, mapped Databricks SP, and group membership" }
  },
  "tool_access": {
    "check_identity": null,
    "query_audit_log": ["executive", "finance", "admin"],
    "ask_supervisor": ["executive", "admin"]
  },
  "tool_order": ["check_identity", "get_region_summary", "query_sales_data"]
}
```

Caching headers make freshness cheap:

```
Cache-Control: public, max-age=60, stale-while-revalidate=300
X-Config-Version: 7
ETag: "v7"
```

Serve cached for 60s, serve stale for 5 minutes while refreshing in the background, and let
consumers send `If-None-Match: "v7"` for conditional `304 Not Modified` responses.

## Versioning with Unity Catalog

Two layers combine well.

**Layer 1, explicit version (application-level).** A `config_versions` table tracks every
change with a monotonic integer, the full JSON snapshot, who/when, a human-readable summary,
and an `is_active` flag.

```sql
CREATE TABLE catalog.config.config_versions (
  version        INT,
  config_json    STRING,
  updated_by     STRING,
  updated_at     TIMESTAMP,
  change_summary STRING,
  is_active      BOOLEAN DEFAULT false
);

-- publish a new version, deactivate the old one (rollback is the reverse)
UPDATE catalog.config.config_versions SET is_active = false WHERE is_active = true;
INSERT INTO catalog.config.config_versions
VALUES (8, '{"roles": []}', 'admin@example.com', current_timestamp(), 'Added analyst role', true);

-- what /config serves
SELECT config_json, version, updated_at, updated_by
FROM catalog.config.config_versions WHERE is_active = true;
```

**Layer 2, Delta time travel (infrastructure-level).** Delta versioning gives automatic
history with no extra code: `DESCRIBE HISTORY`, `TIMESTAMP AS OF`, and `RESTORE TABLE ... TO
VERSION AS OF` for disaster recovery.

Use both because they answer different concerns:

| Concern | Explicit version | Delta time travel |
|---|---|---|
| API contract (`X-Config-Version`) | clean integer | table version is not the config version |
| Rollback | flip `is_active` | `RESTORE` (destructive) |
| Audit trail | `change_summary` column | commit-level, no semantic info |
| Cross-table consistency | one version ties all config | per-table version |

## Provider-agnostic interface

Use an adapter so the backend can change without touching the server.

```python
from abc import ABC, abstractmethod

class ConfigProvider(ABC):
    @abstractmethod
    def load(self) -> dict: ...
    @abstractmethod
    def load_version(self, version: int) -> dict | None: ...
    @abstractmethod
    def current_version(self) -> int: ...
```

Implementations map to deployment shape: a Unity Catalog Delta table (Databricks-native,
SQL update propagates in under a minute, versioned + audited), Postgres/Lakebase (apps
already on Postgres), a JSON file on a Volume/S3/GCS/ADLS (simplest, CI-driven), an env var
(serverless, but no hot deploy), or Redis/Valkey (low-latency, multi-region, sub-second).

Wrap any provider in a TTL cache with last-known-good fallback so a transient source outage
serves stale config instead of failing:

```python
class CachedConfigProvider:
    def __init__(self, provider, ttl_seconds=60):
        self._provider, self._ttl = provider, ttl_seconds
        self._cache, self._cache_ts, self._lock = None, 0, threading.Lock()

    def get(self) -> dict:
        now = time.time()
        if self._cache and (now - self._cache_ts) < self._ttl:
            return self._cache
        try:
            fresh = self._provider.load()
            with self._lock:
                self._cache, self._cache_ts = fresh, now
            return fresh
        except Exception:
            if self._cache:
                return self._cache   # serve stale
            raise                    # hard fail only on first load
```

A front end mirrors this: `HEAD /config` for a version check, fetch on change, cache in
session storage, fall back to the cached copy on error.

## Hot deploy and rollback

A change is an admin SQL update: deactivate the current version, insert (or reactivate) the
target one. The server cache expires within the TTL and serves the new version; the front end
sees a new `X-Config-Version` and re-renders. No deploys, restarts, or PRs. Rollback is the
same flip in reverse; if the table itself is corrupted, `RESTORE TABLE ... TO VERSION AS OF`
recovers it.

## Security

| Concern | Mitigation |
|---|---|
| Config tampering | UC governance: only admins hold INSERT/UPDATE on config tables |
| SP UUIDs leaking to the client | The `/config` response excludes SP mappings; SP-to-role mapping stays server-side |
| Config injection | Validate against a JSON schema before write |
| Stale-config attack | Enforce version monotonicity; reject a version lower than the cached one |
| Credential leakage | Config never contains secrets |

## Scaling tiers

| Tier | Backend | Hot deploy | When |
|---|---|---|---|
| 1, file | JSON on Volume/S3 | file upload, ~60s | PoC, demos, single team |
| 2, database | UC table or Postgres | SQL update, ~60s | production, multi-team, audit required |
| 3, edge cache | DB + Redis/KV at edge | push, <1s | global distribution, high concurrency |

Start at Tier 2. Move to Tier 3 only when latency or global distribution demands it; most
apps never need it.

## Related

- [Custom MCP Principles](custom-mcp-principles.md), the server that serves this config and enforces tool access
- [Identity: Authorization](../identity/authorization.md), where tool-access roles map to UC grants
- [Observability: Audit Reference](../observability/audit-reference.md), attributing config changes and tool calls

## Public References

- [Delta table history and time travel](https://docs.databricks.com/aws/en/delta/history)
- [Unity Catalog privileges](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/privileges)
