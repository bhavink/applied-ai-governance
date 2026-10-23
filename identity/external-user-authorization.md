# External-User Authorization

> **Golden path:** external users authenticate with their own identity provider, the application exchanges that identity for a Databricks OAuth token issued to one least-privileged service principal, and Unity Catalog authorizes each person by an immutable identifier carried in the token's custom identity claim.

This is the repository's only recommended authorization pattern for external users who do not have Databricks accounts. Do not create a service principal per user or role, pass user identity as an application-supplied SQL parameter, or depend on service-principal group membership for end-user authorization.

## Architecture

1. The external IdP authenticates the person and issues a signed token.
2. The trusted backend validates issuer, audience, signature, expiry, and subject.
3. The backend exchanges the identity for a Databricks OAuth token issued to the workload's shared service principal and includes an immutable external subject in the custom identity claim.
4. The application calls a SQL warehouse through JDBC, the Statement Execution API, or a supported Genie Agents API path using that token.
5. A Unity Catalog row filter reads `current_oauth_custom_identity_claim()` and resolves the subject through a governed entitlement table.
6. A missing claim, missing entitlement, or disabled identity returns no rows.

The claim identifies the caller; it does not contain their permissions. Entitlements stay in Unity Catalog so access changes do not require changing token-minting code.

## Canonical implementation

Deploy [external-user-authorization.sql](external-user-authorization.sql). The abbreviated
shape is shown below.

```sql
CREATE TABLE governance.identity.external_user_entitlements (
  external_subject STRING NOT NULL,
  resource_id      STRING NOT NULL,
  enabled          BOOLEAN NOT NULL
);

CREATE OR REPLACE FUNCTION governance.identity.can_read_resource(resource_id STRING)
RETURNS BOOLEAN
RETURN EXISTS (
  SELECT 1
  FROM governance.identity.external_user_entitlements entitlement
  WHERE entitlement.external_subject = current_oauth_custom_identity_claim()
    AND entitlement.resource_id = resource_id
    AND entitlement.enabled = TRUE
);

ALTER TABLE production.application.customer_resources
SET ROW FILTER governance.identity.can_read_resource ON (resource_id);
```

Use an opaque, immutable subject identifier. Do not put email addresses, roles, permissions, secrets, or sensitive attributes in the claim. Anyone holding the token can read the claim.

## Security requirements

- Fail closed. `current_oauth_custom_identity_claim()` returns `NULL` when the token has no claim; equality and `EXISTS` predicates must therefore return `FALSE` or `NULL`.
- Never use the claim in `IDENTIFIER`, `EXECUTE IMMEDIATE`, regular expressions, or SQL text. Treat it as untrusted input and only compare it as a value.
- Grant the service principal only the API scopes, warehouse permissions, and Unity Catalog privileges required by the application.
- Do not expose an unfiltered base table or view that bypasses the row filter.
- Restrict direct access to the entitlement table. The filter function, not the application, owns authorization.
- Correlate the external subject, service principal, request ID, SQL statement, and agent trace in the application audit record. Platform audit records still identify the service principal.

## Platform requirements

- Databricks SQL or Databricks Runtime 19.7 or later.
- Unity Catalog and a SQL warehouse for the documented row-filter pattern.
- A workspace-assigned service principal and an OAuth token containing the custom identity claim.
- A supported SQL surface such as JDBC, Statement Execution API, or Genie Agents API.

The claim is a string of at most 1,000 printable ASCII characters. A normal SQL Editor session does not carry the application's custom-claim token and therefore returns `NULL`; test through the production authentication path.

## Validation gates

Use [external-user-authorization-validation.sql](external-user-authorization-validation.sql)
through the production token path. Generate the token with
[external-user-oauth-exchange.sh](external-user-oauth-exchange.sh); the exchange request field
is `custom_claim`, while SQL reads it with `current_oauth_custom_identity_claim()`.

1. Two external subjects using the same service principal receive different authorized rows.
2. A token without the claim receives zero rows.
3. An unknown, disabled, empty, or malformed subject receives zero rows.
4. The service principal cannot query an unfiltered bypass object.
5. Revoking an entitlement takes effect without redeploying the application.
6. Audit and MLflow traces correlate the external subject with the service principal request.

## Boundary with other identity patterns

- Native Databricks users use OBO and `current_user()`.
- Non-interactive workloads use M2M and service-principal authorization.
- External people without Databricks accounts use this custom-identity-claim pattern.

These are identity boundaries, not interchangeable implementation choices.

## References

- [current_oauth_custom_identity_claim](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/functions/current_oauth_custom_identity_claim)
- [Filter data per end user with OAuth custom identity claims](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-custom-identity-claims)
- [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/)
