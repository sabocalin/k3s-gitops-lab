#!/bin/sh
# #39: the push deploy, run by .github/workflows/deploy-push.yml on the tailnet. Applies
# exactly the manifests render-k8s.sh rendered and checked (not kubectl's own kustomize),
# as the GitHub OIDC identity bound to Role github-deployer (k8s/namespaces/push/rbac.yaml).
#
#   scripts/deploy-push.sh <rendered dir>     (output of scripts/render-k8s.sh)
#
# Before applying, it proves the identity is what it should be and nothing more: the
# expected user name, can deploy in push, cannot touch gitops or Secrets, and a token for
# another audience is refused. After: rollout complete, every pod on the rendered digest,
# and the public URL answering.
#
# DEPLOY_WAIT_SECONDS (default 0): for a freshly built node (#64, the rebuild workflow),
# first wait up to that long for the API and the deployer's RoleBinding (applied by the
# node's own bootstrap), and at the end for the certificate cert-manager issues for the
# new cluster. 0 keeps a normal deploy strict: no waiting, any failure fails at once.
set -eu

rendered=${1:?usage: $0 <rendered dir>}
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
KUBECTL=$(fetch_tool kubectl)

API=https://k3s-node.taild18d72.ts.net:6443
USER_NAME="github:repo:sabocalin@238511101/k3s-gitops-lab@1385841640:environment:production"
PUBLIC_URL=https://k3s-gitops-lab.duckdns.org
manifests=$rendered/push.yaml
[ -s "$manifests" ] || { echo "deploy: $manifests missing or empty" >&2; exit 1; }

kubeconfig=$(mktemp)
trap 'rm -f "$kubeconfig"' EXIT
# The CA is public (k8s/ci/cluster-ca.crt, from the cluster). The credential is not a
# file: kubectl runs ci-github-token.sh for a fresh GitHub OIDC token each time.
cat >"$kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s-gitops-lab
    cluster:
      server: $API
      certificate-authority: $PWD/k8s/ci/cluster-ca.crt
users:
  - name: github-actions
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: $PWD/scripts/ci-github-token.sh
        interactiveMode: Never
contexts:
  - name: deploy
    context: {cluster: k3s-gitops-lab, user: github-actions, namespace: push}
current-context: deploy
EOF
k() { "$KUBECTL" --kubeconfig "$kubeconfig" "$@"; }

WAIT=${DEPLOY_WAIT_SECONDS:-0}
case $WAIT in '' | *[!0-9]*) echo "deploy: DEPLOY_WAIT_SECONDS must be a number" >&2; exit 1 ;; esac
# Retry <command...> every 10 s until it succeeds or WAIT seconds have passed.
retry() { # <what> <command...>
  what=$1; shift
  end=$(($(date +%s) + WAIT))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    echo "waiting for $what..."
    sleep 10
  done
}
if [ "$WAIT" -gt 0 ]; then
  echo "::group::Wait for the API and the deployer's RBAC (up to ${WAIT}s)"
  retry "the API and RoleBinding github-deployer" k auth can-i create deployments.apps -n push ||
    { echo "deploy: no API or RBAC after ${WAIT}s" >&2; exit 1; }
  echo "::endgroup::"
fi

echo "::group::Identity and least privilege"
who=$(k auth whoami -o jsonpath='{.status.userInfo.username}')
[ "$who" = "$USER_NAME" ] || { echo "deploy: logged in as '$who', expected '$USER_NAME'" >&2; exit 1; }
echo "logged in as $who"
expect() { # <yes|no> <can-i args...>
  want=$1; shift
  got=$(k auth can-i "$@" 2>/dev/null || true)
  printf '%-4s (want %-3s) can-i %s\n' "$got" "$want" "$*"
  [ "$got" = "$want" ]
}
expect yes create deployments.apps -n push
expect yes patch ingresses.networking.k8s.io -n push
expect no create deployments.apps -n gitops
expect no get secrets -n push
expect no patch networkpolicies.networking.k8s.io -n push
expect no delete deployments.apps -n push
# Negative: the same job's token, minted for another audience, must not log in at all.
if OIDC_AUDIENCE=not-k3s-gitops-lab k auth whoami >/dev/null 2>&1; then
  echo "deploy: a token for audience not-k3s-gitops-lab was accepted" >&2
  exit 1
fi
echo "token for another audience: refused (as it should be)"
echo "::endgroup::"

echo "::group::Apply"
k apply -f "$manifests"
k -n push rollout status deployment/lab-api --timeout=180s
echo "::endgroup::"

echo "::group::Verify"
want=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$manifests")
digest=${want#*@}
# Running pods that are not shutting down (old pods linger for their 5 s preStop, #28).
running=$(k -n push get pods -l app.kubernetes.io/name=lab-api -o json | jq -r \
  '.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null)
   | .status.containerStatuses[0].imageID')
stale=$(printf '%s\n' "$running" | grep -v -F "$digest" || true)
[ -z "$stale" ] || { echo "deploy: pods not on $digest: $stale" >&2; exit 1; }
echo "all $(printf '%s\n' "$running" | grep -c .) running pods on $digest"
health() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_URL/health")" = 200 ]; }
if [ "$WAIT" -gt 0 ]; then
  # A new cluster: DuckDNS moves to the new IP and cert-manager issues a new certificate.
  retry "$PUBLIC_URL/health (DNS, certificate)" health
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_URL/health")
[ "$code" = 200 ] || { echo "deploy: $PUBLIC_URL/health answered $code" >&2; exit 1; }
echo "$PUBLIC_URL/health -> 200"
echo "::endgroup::"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # backticks are Markdown
  printf '### Deployed to `push`\n\n| | |\n|---|---|\n| Image | `%s` |\n| As | `%s` |\n| URL | %s |\n' \
    "$want" "$who" "$PUBLIC_URL" >>"$GITHUB_STEP_SUMMARY"
fi
