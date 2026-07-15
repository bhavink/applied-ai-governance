<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: ai/lakebase.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/oltp/
    - https://learn.microsoft.com/en-us/azure/databricks/oltp
  This file is auto-prepared and human-reviewed before publish.
-->

# Agent Memory — Governed OLTP for Agents

> **TL;DR**: Lakebase is the Databricks-managed PostgreSQL service. For AI agents, it's the right home for **conversation state, tool-call logs, per-user preferences, and short-lived memory** — the kinds of small, frequently-read writes that don't belong in Delta. Lakebase is registered in Unity Catalog, supports synced tables to and from Delta, and inherits Databricks identity for both the management API and database access. Treat agent memory the same way you treat any sensitive data store: per-user row-level security via Postgres RLS, identity-aware access via short-lived credentials, and audit through UC.

---

## When Agent Memory Belongs in Lakebase

| Need | Fit |
|---|---|
| Multi-turn conversation history with low-latency reads | Strong fit — sub-millisecond Postgres reads |
| Per-user preferences and feature flags | Strong fit — small writes, frequent reads |
| Short-term agent scratchpad / planning state | Strong fit |
| Tool-call audit log with hot-path access | Strong fit — write-once, read-by-session |
| RAG retrieval over millions of vector rows | Use Vector Search, not Postgres |
| Long-term agent telemetry and analytics | Use Delta + system tables, not Postgres |
| Streaming ingestion | Use Lakeflow pipelines |

---

## Lakebase Autoscaling vs Provisioned

| Capability | Autoscaling | Provisioned |
|---|---|---|
| Compute scaling | Automatic | Manual |
| Scale-to-zero on inactivity | Yes | No |
| Copy-on-write branching | Yes | No |
| Point-in-time restore | Yes | Yes |
| Read replicas | Yes | Yes |
| Private Link | Yes | Yes |
| Compliance profiles (HIPAA, C5, TISAX) | Yes | No |
| Unity Catalog registration | Yes | Yes |
| Synced tables (Delta ↔ Postgres) | Yes | Yes |
| Databricks Apps integration | Yes | Yes |

**New instances default to Autoscaling** since 2026-03-12. For agent memory workloads — bursty, often idle, frequently rolled forward into branches for testing — Autoscaling is the default choice.

---

## Two Auth Layers — Don't Confuse Them

Lakebase has two distinct identity boundaries:

| Boundary | Purpose | Token type |
|---|---|---|
| **Platform management** | Create/delete projects, branches, computes; configure HA, networking | Databricks OAuth token with `postgres` scope |
| **Database access** | Connect to the Postgres wire protocol; run SQL | Short-lived OAuth token via `generate-database-credential`, used as the Postgres password |

For an agent app, this means:

1. **Provisioning** the Lakebase instance (one-time): platform-management API, run by an admin SP with `postgres` scope.
2. **Connecting** at runtime (every session): the agent calls `generate_database_credential()`, gets a 1-hour token, uses it as the Postgres password.

> **Best practice**: rotate the database credential on the agent's existing schedule (every <1 hour), not as a manual step. The SDK handles this — `WorkspaceClient().postgres.generate_database_credential()`.

---

## Identity Propagation Into Postgres

When an agent connects to Lakebase using a Databricks-issued credential, `current_user` in Postgres resolves to the Databricks identity. Use this to enforce per-user access at the database layer:

```sql
-- Conversation history table, per-user RLS
CREATE TABLE agent_conversations (
  conversation_id  UUID PRIMARY KEY,
  user_email       TEXT NOT NULL,
  message_role     TEXT NOT NULL,
  content          TEXT NOT NULL,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE agent_conversations ENABLE ROW LEVEL SECURITY;

-- Policy: users see only their own conversations
CREATE POLICY user_can_see_own_conversations ON agent_conversations
  FOR SELECT
  USING (user_email = current_user);

CREATE POLICY user_can_insert_own_conversations ON agent_conversations
  FOR INSERT
  WITH CHECK (user_email = current_user);
```

This pattern is functionally equivalent to UC row filters for Delta — but enforced inside Postgres, on every query, with native PG primitives.

---

## Synced Tables — Keeping Memory and Lakehouse Aligned

Lakebase ↔ Delta synced tables let agent memory share the lakehouse:

- **Delta → Lakebase**: serve curated reference data (entity catalogs, policy tables) to the agent through Postgres without duplicating storage.
- **Lakebase → Delta**: snapshot conversation history for offline analysis, scorer evaluation, and audit retention.

Pair the two for a complete pattern: agent reads reference tables from Postgres (fast), writes new conversation rows to Postgres, and a sync job archives those rows to Delta where production monitoring scorers and audit dashboards can reach them.

### Registering Lakebase in Unity Catalog

Registering a Lakebase database in Unity Catalog creates a **read-only catalog** mirroring the Postgres schema, queryable from a serverless SQL warehouse alongside Delta tables:

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.postgres import Catalog, CatalogCatalogSpec

w = WorkspaceClient()
catalog = w.postgres.create_catalog(
    catalog=Catalog(spec=CatalogCatalogSpec(
        postgres_database="agent_memory_db",
        branch="projects/agent-memory/branches/production",
    )),
    catalog_id="agent_memory_catalog",
).wait()
```

This is what makes "reference data shared with the agent" and "long-term retention" work as UC-governed patterns: once registered, the agent's conversation tables get UC permissions, lineage tracking, and audit logging, and can be joined against Delta tables in the same query (`SELECT ... FROM agent_memory_catalog.public.conversations JOIN main.analytics.events ON ...`). Registration is one catalog per database, bound to a specific branch; the UC catalog is read-only, so writes go directly to Postgres and reads flow through UC.

### Change Data Capture — Full History to Delta

Beyond point-in-time synced tables, Lakebase also supports continuous change data capture from Postgres to Delta, preserving every insert/update/delete as history (SCD Type 2). For agent memory this is the pattern to reach for when you need a complete audit trail of conversation edits and tool-call state changes, not just current-state snapshots.

```sql
-- Set replica identity before the table receives writes
ALTER TABLE agent_conversations REPLICA IDENTITY FULL;
```

CDC writes to a `lb_<table_name>_history` Delta table with `_change_type`, `_timestamp`, `_lsn`, and `_xid` system columns. Build a current-state view with a window function over `_lsn` when you need to query the latest row per key from the history table.

---

## Data API — HTTP Access Without a Postgres Driver

For agent runtimes that can't hold a Postgres connection (browser-side tools, lightweight serverless functions, external integrations), Lakebase exposes a PostgREST-compatible **Data API**: a single `authenticator` role fronts the HTTP layer, an OAuth token authenticates the caller, and PostgREST switches to a per-user Postgres role before evaluating RLS.

```bash
# GET with filter — open tasks assigned to the agent's session
curl -s "$BASE_URL/tasks?status=eq.open&limit=10" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json"

# POST insert — record a new agent action
curl -s "$BASE_URL/tasks" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"title": "Review PR", "status": "open", "assigned_to": "user@company.com"}'
```

Row-level security policies enforce access the same way as a direct Postgres connection — the Data API is a transport, not a separate authorization model.

## Governance Levers

| Concern | How Lakebase enforces it |
|---|---|
| Who can connect at all | Account-level network policy + workspace IP access lists + Lakebase compute reachability |
| Who can read which rows | Postgres RLS policies keyed on `current_user` |
| What columns are visible | Postgres views + GRANTs, or RLS expressions |
| Database password rotation | Short-lived `generate-database-credential` tokens (≤1 hr lifetime) |
| Lineage with the lakehouse | UC registration + synced tables tracked in UC |
| Audit | UC audit logs for management operations; Postgres `pg_audit` extension for in-database events |

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| A multi-user chat agent | Postgres RLS keyed on `current_user`; one row policy per table |
| A short-term agent scratchpad | Schema scoped to the agent SP; rows tagged with `session_id` and TTL'd by a job |
| Reference data shared with the agent | Synced table from Delta to Lakebase (one source of truth in the lakehouse) |
| Long-term retention of conversations | Synced table from Lakebase to Delta + production monitoring scorers on the Delta copy |
| Compliance-bound workloads (HIPAA, C5) | Lakebase Autoscaling with the appropriate compliance profile + Private Link |
| Branching for safe schema changes | Autoscaling branches — copy-on-write isolation, instant rollback |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Agent code holding a long-lived Postgres password | `generate-database-credential` per session; ≤1 hr tokens |
| Storing per-user data without RLS | RLS policies on every table that holds user-scoped data |
| Using Lakebase as primary analytics store | Use Delta; sync hot data to Lakebase for low-latency reads |
| Mixing platform-management and database credentials | Two distinct auth flows — keep them separate |
| Public-internet exposure of the Lakebase endpoint | Private Link + account-level ingress policy |
| One Lakebase instance for unrelated workloads | Per-team or per-app instances; UC governs ownership |

---

## Capacity Planning

Plan agent memory schemas against Lakebase's per-project limits so scratchpad/session tables don't collide with other quotas on a shared instance:

| Limit | Value |
|---|---|
| Concurrent computes per project | 20 |
| Read replicas per branch | 6 |
| Branches per project | 500 |
| Logical data per project | 8 TB |
| History (point-in-time restore) retention | 30 days |
| Min scale-to-zero interval | 60 seconds |

---

## Related

- [`uc-governance.md`](uc-governance.md) — UC registration and grants on Lakebase databases
- [`network-controls.md`](network-controls.md) — Ingress controls including Lakebase Compute access type
- [`../identity/authentication.md`](../identity/authentication.md) — OBO and M2M for the agent connecting to Lakebase
- [`../observability/agent-tracing.md`](../observability/agent-tracing.md) — Trace tags for memory operations

---

## Public References

- [Lakebase overview](https://docs.databricks.com/aws/en/oltp/)
- [Lakebase authentication](https://learn.microsoft.com/en-us/azure/databricks/oltp/projects/authentication)
- [Synced tables (Delta ↔ Postgres)](https://docs.databricks.com/aws/en/oltp/sync-data/)
