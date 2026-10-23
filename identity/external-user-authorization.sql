-- Replace object names and the principal before deployment.
-- Requires Databricks SQL or Databricks Runtime 19.7+.

CREATE SCHEMA IF NOT EXISTS governance.identity;

CREATE TABLE IF NOT EXISTS governance.identity.external_user_entitlements (
  external_subject STRING NOT NULL COMMENT 'Opaque immutable subject from the trusted IdP',
  resource_id      STRING NOT NULL COMMENT 'Governed resource identifier present on protected rows',
  enabled          BOOLEAN NOT NULL COMMENT 'Revocation switch evaluated at query time',
  valid_from       TIMESTAMP NOT NULL,
  valid_until      TIMESTAMP,
  updated_at       TIMESTAMP NOT NULL,
  updated_by       STRING NOT NULL
)
COMMENT 'Authoritative external-user entitlement mapping';

CREATE OR REPLACE FUNCTION governance.identity.can_read_external_resource(resource_id STRING)
RETURNS BOOLEAN
COMMENT 'Fail-closed external-user authorization policy'
RETURN EXISTS (
  SELECT 1
  FROM governance.identity.external_user_entitlements entitlement
  WHERE entitlement.external_subject = current_oauth_custom_identity_claim()
    AND entitlement.resource_id = resource_id
    AND entitlement.enabled = TRUE
    AND current_timestamp() >= entitlement.valid_from
    AND (entitlement.valid_until IS NULL OR current_timestamp() < entitlement.valid_until)
);

ALTER TABLE production.application.customer_resources
SET ROW FILTER governance.identity.can_read_external_resource ON (resource_id);

GRANT USE CATALOG ON CATALOG production TO `<shared-service-principal>`;
GRANT USE SCHEMA ON SCHEMA production.application TO `<shared-service-principal>`;
GRANT SELECT ON TABLE production.application.customer_resources TO `<shared-service-principal>`;
GRANT EXECUTE ON FUNCTION governance.identity.can_read_external_resource TO `<shared-service-principal>`;

-- Do not grant the shared service principal direct access to entitlement administration
-- interfaces or to an unfiltered copy of the protected data.
