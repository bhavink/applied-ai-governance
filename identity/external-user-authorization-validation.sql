-- Run through the production token path, never only through SQL Editor.

SELECT
  current_user() AS workload_identity,
  current_oauth_custom_identity_claim() AS external_subject;

SELECT resource_id, COUNT(*) AS visible_rows
FROM production.application.customer_resources
GROUP BY resource_id
ORDER BY resource_id;

-- Required test matrix. Mint a separate token for each test and record the result.
-- 1. Subject A: only resources explicitly mapped to A are returned.
-- 2. Subject B: only resources explicitly mapped to B are returned.
-- 3. Missing custom_claim: zero rows.
-- 4. Unknown subject: zero rows.
-- 5. Disabled entitlement: zero rows.
-- 6. Expired entitlement: zero rows.
-- 7. Revoked entitlement: access disappears without redeployment.
-- 8. Shared SP direct query: no unfiltered table or view is reachable.
