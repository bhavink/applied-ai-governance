#!/usr/bin/env bash
set -euo pipefail

: "${DATABRICKS_HOST:?Set DATABRICKS_HOST without a trailing slash}"
: "${DATABRICKS_SP_APPLICATION_ID:?Set DATABRICKS_SP_APPLICATION_ID}"
: "${IDP_SUBJECT_TOKEN:?Set IDP_SUBJECT_TOKEN to the validated IdP JWT}"
: "${EXTERNAL_SUBJECT:?Set EXTERNAL_SUBJECT to the immutable external subject}"

if [[ ${#EXTERNAL_SUBJECT} -gt 1000 || -z "${EXTERNAL_SUBJECT//[[:space:]]/}" ]]; then
  echo "EXTERNAL_SUBJECT must contain 1-1000 printable ASCII characters" >&2
  exit 1
fi

if [[ "$EXTERNAL_SUBJECT" == *[!\ -~]* ]]; then
  echo "EXTERNAL_SUBJECT must contain printable ASCII only" >&2
  exit 1
fi

curl --fail-with-body --silent --show-error \
  --request POST \
  --url "${DATABRICKS_HOST}/oidc/v1/token" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${DATABRICKS_SP_APPLICATION_ID}" \
  --data-urlencode "subject_token=${IDP_SUBJECT_TOKEN}" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "scope=sql" \
  --data-urlencode "custom_claim=${EXTERNAL_SUBJECT}"
