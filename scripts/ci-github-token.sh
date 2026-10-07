#!/bin/sh
# #39: kubectl exec credential plugin for GitHub Actions. kubectl runs this whenever it
# needs a token; it prints a fresh GitHub OIDC token (audience k3s-gitops-lab) as an
# ExecCredential. The API server accepts it via ansible/roles/k3s/templates/
# authentication-config.yaml.j2. Nothing is stored: each token lives a few minutes.
#
# Needs the job permission `id-token: write` (GitHub then sets ACTIONS_ID_TOKEN_REQUEST_*).
# OIDC_AUDIENCE overrides the audience (deploy-push.sh uses that for a negative test).
set -eu

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC (job needs permissions: id-token: write)}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?no GitHub OIDC (job needs permissions: id-token: write)}"

token=$(curl -sf --max-time 10 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${OIDC_AUDIENCE:-k3s-gitops-lab}" | jq -r .value)
[ -n "$token" ] && [ "$token" != null ] || {
  echo "ci-github-token: GitHub returned no token" >&2
  exit 1
}
# jq builds the JSON, so the token is never interpolated into a format string.
jq -cn --arg t "$token" '{apiVersion: "client.authentication.k8s.io/v1", kind: "ExecCredential", status: {token: $t}}'
