# Authentication Patterns for Databricks AI Products

> **Technical overview for authentication and authorization across Databricks AI products**
>
> For the complete token flows, OAuth scope reference, and identity models, see the canonical reference: [reference/identity-and-auth-reference.md](reference/identity-and-auth-reference.md)
>
> For the OBO vs M2M decision framework, see: [reference/obo-vs-m2m-decision-matrix.md](reference/obo-vs-m2m-decision-matrix.md)

---

## Important Disclaimers

### Multi-Cloud Documentation

This guide primarily links to **AWS Databricks documentation** for consistency. However, all authentication concepts apply universally across **AWS, Azure, and GCP**.

- [AWS Documentation](https://docs.databricks.com/aws/en/)
- [Azure Documentation](https://learn.microsoft.com/en-us/azure/databricks/)
- [GCP Documentation](https://docs.databricks.com/gcp/en/)

### Guidance vs Official Documentation

- This guide represents **practical guidance and best practices**, not official Databricks positions
- Always consult [official Databricks documentation](https://docs.databricks.com) for authoritative information
- Databricks features evolve rapidly - **verify current capabilities** and syntax in official docs

---

## Overview

Databricks provides a **unified authentication and authorization model** that works consistently across all AI products (Genie Space, Agent Bricks, Databricks Apps, Model Serving, Vector Search, AI/BI Dashboards).

### Three Universal Authentication Patterns

Every Databricks AI application uses one or more of these three patterns:

| Pattern | Token Type | Identity in Audit | Use Case |
|---------|-----------|-------------------|----------|
| **Automatic Passthrough (M2M)** | Short-lived SP token | SP UUID | Batch jobs, automation, shared resources |
| **On-Behalf-Of User (OBO)** | User token | Human email | User-facing apps, per-user data access |
| **Manual Credentials** | External API key | Depends on service | External LLMs, external MCP, third-party SaaS |

### When to Use Each

| Question | Answer |
|---|---|
| User should only see their data? | **OBO** -- UC row filters, column masks, ABAC fire as the user |
| Everyone sees the same data? | **M2M** -- SP credentials, shared access |
| Need human identity in platform audit? | **OBO** where possible; app-level audit for M2M paths |
| External API or third-party service? | **Manual Credentials** |
| Background/batch processing? | **M2M** |

### Key Resources

| Topic | Document |
|---|---|
| Complete auth reference (token flows, scopes, identity models) | [reference/identity-and-auth-reference.md](reference/identity-and-auth-reference.md) |
| OBO vs M2M decision framework | [reference/obo-vs-m2m-decision-matrix.md](reference/obo-vs-m2m-decision-matrix.md) |
| UC authorization layers | [02-AUTHORIZATION-WITH-UC.md](02-AUTHORIZATION-WITH-UC.md) |
| UC policy design (`current_user()` vs `is_member()`) | [UC-POLICY-DESIGN-PRINCIPLES.md](UC-POLICY-DESIGN-PRINCIPLES.md) |
| Genie authorization cookbook | [reference/genie-authorization-cookbook.md](reference/genie-authorization-cookbook.md) |
| Observability and audit architecture | [reference/observability-and-audit.md](reference/observability-and-audit.md) |

---

## Pattern 1: Automatic Passthrough (M2M)

The platform issues short-lived credentials for a dedicated service principal tied to declared resources at log time.

- **How it works**: Resources declared when logging the agent; platform auto-provisions an SP with least-privilege access
- **UC enforcement**: SP-level permissions (grants on catalogs, schemas, tables)
- **Audit trail**: SP UUID in `system.access.audit` -- human identity is NOT captured
- **Docs**: [Automatic Passthrough](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#automatic-authentication-passthrough), [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m.html)

---

## Pattern 2: On-Behalf-Of User (OBO)

The agent or app runs as the end user. UC enforces row filters, column masks, and ABAC policies per user.

- **How it works**: User identity passed via OAuth token; client initialized inside `predict()` at request time
- **UC enforcement**: Per-user row filters, column masks, ABAC, governed tags
- **Audit trail**: Human email in `system.access.audit`
- **Scope requirement**: Declare required scopes (`sql`, `dashboards.genie`, `model-serving`, etc.)
- **Docs**: [OBO Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#on-behalf-of-user-authentication), [OAuth U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m.html)

> For the complete OAuth scope map (including Azure-specific scopes, the `sql` scope configuration paths, and UI vs CLI differences), see [reference/identity-and-auth-reference.md](reference/identity-and-auth-reference.md#4-oauth-scope-reference).

---

## Pattern 3: Manual Credentials

External API keys or SP OAuth credentials stored in Databricks Secrets for services outside the platform.

- **How it works**: Credentials stored in workspace secrets or environment variables; combined with M2M or OBO for Databricks resources
- **UC enforcement**: None (external to Databricks)
- **Audit trail**: External service logs only
- **Docs**: [Manual Auth](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication#manual-authentication), [Secrets](https://docs.databricks.com/aws/en/security/secrets/)

---

## Databricks AI Products

| Product | Description | Documentation |
|---------|-------------|---------------|
| **Genie Space** | AI/BI chatbot for natural language queries on data | [Docs](https://docs.databricks.com/en/genie/index.html) |
| **AI/BI Dashboards** | Intelligence dashboards with natural language | [Docs](https://docs.databricks.com/en/dashboards/index.html) |
| **Agent Bricks** | Production-grade AI agents with declarative templates | [Docs](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/) |
| **Databricks Apps** | Custom applications with Streamlit, Dash, Gradio | [Docs](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html) |
| **Model Serving** | Deployed ML models and LLM endpoints | [Docs](https://docs.databricks.com/en/machine-learning/model-serving/index.html) |
| **Vector Search** | Embedding retrieval and similarity search | [Docs](https://docs.databricks.com/aws/en/vector-search/vector-search) |

### Agent Bricks Use Cases

| Use Case | Status | Documentation |
|----------|--------|---------------|
| [Knowledge Assistant](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/knowledge-assistant) | GA | Turn documents into a chatbot |
| [Information Extraction](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/key-info-extraction) | Beta | Unstructured text to structured insights |
| [Custom LLM](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/custom-llm) | Beta | Summarization, text transformation |
| [Multi-Agent Supervisor](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/multi-agent-supervisor) | Beta | Multi-agent systems with Genie + agents |
| [AI/BI Genie](https://docs.databricks.com/aws/en/genie/) | GA | Tables to expert AI chatbot |
| [Code Your Own](https://docs.databricks.com/aws/en/generative-ai/agent-framework/author-agent) | GA | Build with OSS libraries |

---

## Related Resources

- [Unity Catalog Access Control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control) -- Four layers of access control
- [Agent Framework Authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication) -- Detailed auth setup
- [ABAC (Attribute-Based Access Control)](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac)
- [Row Filters & Column Masks](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-row-filter-column-mask.html)
- [Federation Exchange Architecture](reference/federation-exchange-architecture.md) -- Custom MCP governance for external IDP users (token exchange, scope-based access, UC connections)
- [Identity & Governance Presentation](presentations/identity-governance-overview.html) -- OBO vs Federation side-by-side (17 slides)

---

---

## Extended Decision Matrix -- OBO vs M2M vs Proxy Identity

Every API call in a Databricks AI application uses one of three identity models. Choosing the right one per operation is critical for audit fidelity, access control correctness, and confused deputy prevention.

| Model | When to Use | Identity in Audit | Example Operations |
|---|---|---|---|
| **On-Behalf-Of (OBO)** | User-specific data, row-filtered queries, consent-gated operations | Human email | Genie queries, OBO SQL, agent endpoints |
| **Machine-to-Machine (M2M)** | Shared resources, system-level queries, background tasks | Service Principal UUID | Vector Search, CRM sync status, knowledge base queries |
| **Proxy Identity + M2M** | User-specific operations where OBO token lacks required scope | SP UUID (with human email in app-level audit) | Custom MCP tools with M2M SQL + `X-Forwarded-Email` identity |

### Quick Decision Reference

| Question | Answer |
|---|---|
| User should only see their data? | Use OBO (user token + UC row filters) |
| Everyone sees the same data? | Use M2M (app SP credentials) |
| Need SQL as the user? | Add `sql` scope via UI User Authorization, use OBO token with httpx |
| External API via UC connection? | Use UC External MCP Proxy + USE CONNECTION governance |
| MCP server called by another app? | Set `authorization: disabled` on the MCP server app |
| MCP server called by external clients too? | Deploy two instances, or add token-parsing fallback |
| Need human identity in audit? | Use OBO where possible; add app-level audit for M2M paths |
| Preventing confused deputy? | Minimal SP grants + USE CONNECTION as the governance layer |

### OBO SQL Implementation Note

Use `httpx` or `requests` directly for OBO SQL -- not the Databricks SDK. The SDK auto-discovers `DATABRICKS_CLIENT_ID`/`SECRET` from environment variables, causing an auth method conflict:

```python
# Correct -- direct HTTP with user token
import httpx
host = os.environ["DATABRICKS_HOST"]
if not host.startswith("http"):
    host = f"https://{host}"

resp = httpx.post(
    f"{host}/api/2.0/sql/statements",
    headers={"Authorization": f"Bearer {user_token}"},
    json={"warehouse_id": wh_id, "statement": sql, "wait_timeout": "30s"},
)

# Wrong -- SDK conflicts with env vars
# w = WorkspaceClient(token=user_token)  # raises: more than one auth method
```

---

## Confused Deputy Prevention

A **confused deputy** occurs when a service with elevated permissions performs actions on behalf of a user without proper authorization checks. This is a critical risk when building MCP servers and multi-app architectures.

### The Risk

An MCP server SP has `SELECT` on sensitive tables for its M2M tools. An external caller through a UC connection could potentially trigger those tools -- using the MCP server's elevated permissions to access data they should not see.

### Defense: UC Connection Governance

For external-facing MCP servers, **USE CONNECTION is the primary defense**:

```
Caller --> UC External MCP Proxy --> USE CONNECTION check --> MCP server
```

- If the caller lacks `USE CONNECTION` on the UC HTTP Connection, the request **never reaches** the MCP server
- The MCP server's own SP grants are irrelevant for proxied calls -- they only matter for the server's own M2M tools
- `REVOKE USE CONNECTION` instantly cuts off all access through that connection

### Defense Principles

1. **Minimum grants for M2M tools only.** The MCP server SP should hold SELECT/MODIFY only on tables it directly queries. Do not grant SELECT on tables the server does not need.
2. **For UC-proxied external calls, the server is a stateless proxy.** It receives identity via `X-Forwarded-Email` and USE CONNECTION is the governance layer.
3. **USE CONNECTION is the access boundary for external MCP.** Grant or revoke it per user/group. The MCP server itself does not decide who gets access.
4. **Validate caller identity** -- read `X-Forwarded-Email` and enforce per-user access in the tool's WHERE clause.
5. **Prefer row filters + M2M over broad SELECT.** If the server queries tables with mixed-sensitivity data, use UC row filters keyed on the caller's email rather than granting unrestricted SELECT.

### Anti-Patterns

| Anti-pattern | Why It Is Dangerous | Better Approach |
|---|---|---|
| Granting SP `SELECT` on all catalog tables | Any MCP tool bug exposes all data | Grant only on tables the SP's tools actually query |
| Using SP identity for user-facing queries | All queries run as SP, bypassing row filters | Use OBO SQL or filter in WHERE clause using `X-Forwarded-Email` |
| Hardcoding elevation checks in app code only | Code changes bypass governance | Combine with UC row filters or group-based USE CONNECTION grants |

---

## UC Connection Governance for External MCP

### USE CONNECTION as the On/Off Switch

Every call through a UC HTTP Connection (including UC External MCP Proxy calls) requires `USE CONNECTION` on the calling identity:

```sql
-- Grant access
GRANT USE CONNECTION ON CONNECTION my_connection TO `<sp-role-name>`;

-- Revoke access (instant effect)
REVOKE USE CONNECTION ON CONNECTION my_connection FROM `<sp-role-name>`;
```

### Four Connection Auth Methods, Same Governance

| Auth Method | Who Authenticates to External Service | Best For |
|---|---|---|
| **Bearer Token** | Stored token (shared identity) | APIs with static API keys |
| **OAuth M2M** | Client credentials (shared SP) | Service-to-service APIs |
| **OAuth U2M Shared** | Shared user identity | APIs requiring user context |
| **OAuth U2M Per User** | Each user's own identity | GitHub, Salesforce (per-user audit) |

All four are governed by the same `USE CONNECTION` privilege. The auth method determines *how* the connection authenticates; `USE CONNECTION` determines *whether* the call is allowed.

### Important Behaviors

- **Connection owner has implicit USE CONNECTION** that cannot be revoked. `GRANT`/`REVOKE` only affects non-owners. When demoing governance, use a non-owner identity (e.g., the app SP).
- **Revoking USE CONNECTION is immediate** -- no token refresh needed, the proxy rejects the next call.
- **Bearer token connections expire** (~1hr for Databricks tokens). Refresh before demos.

### Service Principal Grants Checklist for Custom MCP

The MCP app's SP needs explicit grants -- a different SP from the main app:

```bash
# Get SP UUID from app
SP=$(databricks apps get my-mcp-server --profile <workspace-profile> | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['service_principal_client_id'])")

# UC grants
databricks sql execute "
  GRANT USE CATALOG ON CATALOG my_catalog     TO \`$SP\`;
  GRANT USE SCHEMA  ON SCHEMA  my_catalog.my_schema TO \`$SP\`;
  GRANT SELECT      ON TABLE   my_catalog.my_schema.my_table  TO \`$SP\`;
" --warehouse <warehouse-id> --profile <workspace-profile>
```

**Common miss**: The main app SP and the MCP app SP are different identities. Grants on one do not carry over to the other.

---

*Last updated: 2026-03-20 -- Added extended decision matrix, confused deputy defense, UC connection governance*
