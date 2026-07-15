<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: auth/m2m-service-principal.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m
  This file is auto-prepared and human-reviewed before publish.
-->

# Service Principal (M2M) Identity

> **TL;DR**: Machine-to-machine (M2M) access uses a **service principal (SP)** as the calling identity instead of a human user. External services — pipelines, API gateways, backend jobs — obtain a token via the OAuth 2.0 client credentials flow and call Databricks APIs as that SP. Governance is applied by putting the SP in a workspace group and granting Unity Catalog privileges to the group, never to the SP directly.

---

## When to use M2M

- Shared data access where every caller should see the same result — knowledge bases, product catalogs, reference tables
- Background jobs, pipelines, or scheduled tasks that don't run in a user's session
- UC Functions or connections that carry their own internal authorization logic
- Any call where the human who triggered the workflow doesn't need to appear in the Unity Catalog audit trail — the SP's identity is the record of interest

If a result must be scoped to the calling human (per-user row filters, personal history, entitlement-based views), use On-Behalf-Of (OBO) instead — M2M returns the same data to every caller. See the SP vs. OBO decision gate below.

---

## Client Credentials Flow

External services authenticate as the SP using the OAuth 2.0 client credentials grant:

```http
POST https://<workspace-host>/oidc/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=<sp-application-id>
&client_secret=<sp-secret>
&scope=all-apis
```

Response:

```json
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

Key points:

- Token TTL is 1 hour. Cache the token and refresh proactively before expiry rather than requesting a new one per call.
- `scope` narrows what the token can do: `all-apis` (all REST APIs), `sql` (SQL warehouse only), `clusters`, `jobs`. Use the minimum scope the workload needs.
- The token is a JWT. `current_user()` in SQL returns the SP's application ID (a UUID), not an email address — this is the key signal that a query ran as M2M rather than OBO.

Minimal Python example:

```python
import requests

def get_sp_token(host, client_id, client_secret, scope="all-apis"):
    resp = requests.post(
        f"{host}/oidc/v1/token",
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": scope,
        },
    )
    resp.raise_for_status()
    return resp.json()["access_token"]
```

For SDK-based workloads, `WorkspaceClient()` auto-discovers `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` / `DATABRICKS_HOST` from the environment and performs this exchange internally — no manual token handling required.

---

## Governance Pattern: SP → Group → UC Privilege

**Core rule: grant Unity Catalog privileges to a workspace group, then add the SP to that group. Never grant privileges directly to an SP.**

```sql
-- Grant to the GROUP, not to the SP directly
GRANT USE CATALOG ON CATALOG prod TO `pipeline-readers`;
GRANT USE SCHEMA ON SCHEMA prod.bronze TO `pipeline-readers`;
GRANT SELECT ON TABLE prod.bronze.sales_raw TO `pipeline-readers`;
GRANT MODIFY ON TABLE prod.bronze.sales_raw TO `pipeline-readers`;
```

Why route through a group instead of granting the SP directly:

- Revoking the SP from the group is an instant access cutoff — no privilege changes to make or audit
- Rotating the SP's secret has zero impact on permissions, since privileges live on the group
- Adding a second SP (for example, a blue-green deployment) is a single group membership add, inheriting all existing privileges
- Audit shows group membership changes as distinct events from data access, which keeps access reviews clean

### One SP per service

- Give each service its own SP and its own purpose-scoped group
- Name the group for the service's function, not the SP (`pipeline-readers`, `api-gateway`, `compliance-reporters`)
- Avoid sharing one SP across multiple services — it collapses the audit trail and makes secret rotation a cross-service event

| Service | SP | Group | UC scope | Token scope |
|---|---|---|---|---|
| ETL pipeline | `etl-pipeline-sp` | `pipeline-readers` | `prod.bronze.* SELECT + MODIFY` | `all-apis` |
| API gateway | `api-gateway-sp` | `api-readers` | `prod.silver.predictions SELECT` | `sql` |
| Compliance job | `compliance-sp` | `compliance-reporters` | `system.access.audit SELECT` | `sql` |

### Adding an SP to a workspace group

```bash
databricks groups patch <group-id> \
  --profile <workspace-profile> \
  --json '{
    "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
    "Operations": [{"op": "add", "path": "members", "value": [{"value": "<sp-user-id>"}]}]
  }'
```

An SP has two identifiers, and they are not interchangeable:

- **Application ID** (a UUID) — what `current_user()` returns in SQL; used for UC grants
- **User/member ID** (a numeric ID) — used in SCIM group operations like the one above

Look up the SP's user ID with:

```bash
databricks api get /api/2.0/preview/scim/v2/ServicePrincipals \
  --profile <workspace-profile> \
  | jq '.Resources[] | select(.applicationId == <app-id>) | .id'
```

### Row filters and column masks with `is_member()`

`is_member()` evaluates the calling identity's **workspace** group membership. For an SP to satisfy an `is_member()` check in a row filter or column mask, add it to the workspace group explicitly — account-level group membership alone is not sufficient.

```sql
CREATE OR REPLACE FUNCTION rls_compliance(val STRING)
RETURNS STRING
RETURN IF(is_member('compliance-reporters'), val, NULL);
```

This pattern works for both SPs (`current_user()` = application ID) and humans (`current_user()` = email), since `is_member()` checks group membership rather than the specific identity type.

For row filters that need to work identically across OBO and M2M callers without depending on workspace-group sync timing, an allowlist table keyed on `current_user()` is a useful alternative pattern:

```sql
RETURN IF(
  EXISTS (SELECT 1 FROM prod.governance.approved_viewers WHERE user_id = current_user()),
  val, NULL
);
-- Add the SP's application ID to the allowlist:
INSERT INTO prod.governance.approved_viewers VALUES ('<sp-application-id>', 'service_principal');
```

---

## Secret Management for External Services

Store SP credentials in a Databricks secret scope rather than in code, plaintext environment variables, or CI/CD configuration without rotation.

```bash
# Create a secret scope
databricks secrets create-scope pipeline-sp --profile <profile>

# Store client ID and secret
databricks secrets put-secret pipeline-sp client-id --string-value <uuid> --profile <profile>
databricks secrets put-secret pipeline-sp client-secret --string-value <secret> --profile <profile>
```

Reference the secrets from a notebook or job:

```python
client_id = dbutils.secrets.get("pipeline-sp", "client-id")
client_secret = dbutils.secrets.get("pipeline-sp", "client-secret")
```

Or inject directly into a job's environment via secret substitution — no code change required:

```json
{
  "spark_env_vars": {
    "DATABRICKS_CLIENT_ID": "{{secrets/pipeline-sp/client-id}}",
    "DATABRICKS_CLIENT_SECRET": "{{secrets/pipeline-sp/client-secret}}"
  }
}
```

For production workloads, back the secret scope with your cloud's key management service:

- AWS: back the scope with AWS Secrets Manager
- Azure: back with Azure Key Vault
- GCP: back with GCP Secret Manager

---

## Audit: SP Actions in System Tables

SP identity appears in `system.access.audit` like any other principal, keyed by application ID rather than email. Three queries worth keeping on hand:

```sql
-- All data access actions by a specific SP in the last 7 days
SELECT event_time, action_name, request_params, response
FROM system.access.audit
WHERE user_identity.email = '<sp-application-id>'
  AND event_date >= current_date() - 7
ORDER BY event_time DESC;

-- Group membership changes for SP groups
SELECT event_time, action_name, request_params
FROM system.access.audit
WHERE action_name IN ('updateGroup', 'addMembersToGroup', 'removeMembersFromGroup')
  AND request_params:group_name IN ('pipeline-readers', 'api-readers', 'compliance-reporters')
ORDER BY event_time DESC;

-- SP token issuance events
SELECT event_time, user_identity.email, request_params
FROM system.access.audit
WHERE action_name = 'tokenLogin'
  AND user_identity.email = '<sp-application-id>'
ORDER BY event_time DESC;
```

---

## SP vs. OBO Decision Gate

| Question | Answer points to M2M | Answer points to OBO |
|---|---|---|
| Should every caller see the same data? | Yes | No — needs per-user scoping |
| Does the workflow run without a human session (job, pipeline, scheduled task)? | Yes | No — interactive user request |
| Does the audit trail need to show the human who triggered the action? | Not required | Required |
| Does the downstream query need `current_user()` to resolve to a human email? | No | Yes |

---

## Gotchas

| Issue | Detail |
|---|---|
| `is_member()` in row filters | Evaluates the workspace group membership of the calling identity. Add the SP to the workspace group explicitly — account-level group membership alone will not satisfy the check. |
| SP has two IDs | Application ID (UUID, used for UC grants and `current_user()`) vs. numeric user ID (used for SCIM group operations). Keep them straight when scripting group membership changes. |
| Granting directly to the SP | Works, but revocation and rotation become per-SP operations. Grant to a group instead so revoking group membership is the single lever for cutting off access. |
| Token not cached | Client-credentials tokens expire in 1 hour. Cache the token and refresh proactively — treat each token request as a network round trip to budget for. |
| M2M for user-scoped data | If a result should differ per calling human, use OBO. M2M returns the same result to every caller regardless of who triggered the workflow. |

---

## Related

- [Authorization](authorization.md) — Token patterns (OBO, M2M, Federation)
- [Federation Exchange](federation.md) — role-based SPs for external IdP callers
- [OAuth Scopes Reference](oauth-scopes-reference.md) — scope governance and blast-radius tiers
- [AppKit Auth Patterns](appkit-auth-patterns.md) — combining M2M, OBO, and U2M in one application

---

## References

- [OAuth machine-to-machine (M2M) auth](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)
- [Unity Catalog access control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication) — SP patterns for AI apps
- [Audit logs (system tables)](https://docs.databricks.com/aws/en/admin/system-tables/audit-logs)
