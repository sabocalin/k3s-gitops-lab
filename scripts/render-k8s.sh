#!/bin/sh
# #27: render every overlay under k8s/overlays/ with the hash-pinned kustomize and check
# the invariants the deploy paths rely on. Same locally (make k8s) and in CI.
#
#   scripts/render-k8s.sh [output dir]     (default: a temporary directory)
#
# Per overlay <name>: exactly one Namespace, named <name>; every other object in that
# namespace (so nothing else cluster-scoped); every container image pinned by digest; pods
# labelled k3s-gitops-lab/deploy-path=<name>; every container with cpu/memory requests and
# limits; exactly one LimitRange and one ResourceQuota (#30). Across overlays: no shared namespace.
# Needs yq (mikefarah, v4) and jq.
set -eu

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
KUSTOMIZE=$(fetch_tool kustomize)

out=${1:-$(mktemp -d)}
mkdir -p "$out"
problems=0
problem() {
  printf 'render: %s\n' "$*" >&2
  problems=$((problems + 1))
}

seen=""
for dir in k8s/overlays/*/; do
  name=$(basename "$dir")
  file=$out/$name.yaml
  if ! "$KUSTOMIZE" build "$dir" >"$file"; then
    problem "$name: kustomize build failed"
    continue
  fi
  # One JSON object per line, for jq.
  objects=$(yq -o json -I0 '.' "$file")

  namespaces=$(echo "$objects" | jq -r 'select(.kind == "Namespace") | .metadata.name')
  [ "$namespaces" = "$name" ] ||
    problem "$name: expected exactly one Namespace named '$name', got '$(echo "$namespaces" | tr '\n' ' ')'"

  outside=$(echo "$objects" | jq -r --arg ns "$name" \
    'select(.kind != "Namespace" and .metadata.namespace != $ns) | "\(.kind)/\(.metadata.name) (namespace: \(.metadata.namespace // "none"))"')
  [ -z "$outside" ] || problem "$name: objects outside namespace '$name': $outside"

  unpinned=$(echo "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[] | select(.image | test("@sha256:[0-9a-f]{64}$") | not) | .image')
  [ -z "$unpinned" ] || problem "$name: images not pinned by digest: $unpinned"

  # #30: every container declares requests and limits for CPU and memory (the quota
  # counts them; a missing limit would make the node's memory unbounded).
  unbounded=$(echo "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[]
     | select([.resources.requests.cpu, .resources.requests.memory, .resources.limits.cpu, .resources.limits.memory] | any(. == null))
     | .name')
  [ -z "$unbounded" ] || problem "$name: containers without cpu/memory requests and limits: $unbounded"

  # #31: hardened pods: non-root, read-only root FS, no privilege escalation, all caps dropped.
  unhardened=$(echo "$objects" | jq -r \
    'select(.spec.template.spec?) | .spec.template.spec as $p | $p.containers[]
     | select(($p.securityContext.runAsNonRoot != true)
              or (.securityContext.readOnlyRootFilesystem != true)
              or (.securityContext.allowPrivilegeEscalation != false)
              or ((.securityContext.capabilities.drop // []) | index("ALL") | not))
     | .name')
  [ -z "$unhardened" ] || problem "$name: containers missing the #31 securityContext: $unhardened"
  psa=$(echo "$objects" | jq -r 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"')
  [ "$psa" = restricted ] || problem "$name: namespace does not enforce Pod Security 'restricted' (got '$psa')"

  for kind in LimitRange ResourceQuota; do
    count=$(echo "$objects" | jq -r --arg k "$kind" 'select(.kind == $k) | .metadata.name' | wc -l | tr -d ' ')
    [ "$count" = 1 ] || problem "$name: expected exactly one $kind, found $count"
  done

  unlabelled=$(echo "$objects" | jq -r --arg ns "$name" \
    'select(.spec.template.metadata?) | select(.spec.template.metadata.labels["k3s-gitops-lab/deploy-path"] != $ns) | "\(.kind)/\(.metadata.name)"')
  [ -z "$unlabelled" ] || problem "$name: pod templates without deploy-path=$name: $unlabelled"

  case " $seen " in *" $namespaces "*) problem "$name: namespace '$namespaces' already used by another overlay" ;; esac
  seen="$seen $namespaces"

  printf 'ok: %-7s -> %s (%s objects: %s)\n' "$name" "$file" \
    "$(echo "$objects" | wc -l | tr -d ' ')" "$(echo "$objects" | jq -r '.kind' | sort | uniq -c | awk '{printf "%s%s ", $2, ($1 > 1 ? "x" $1 : "")}')"
done

if [ "$problems" -gt 0 ]; then
  echo "render: $problems problem(s)" >&2
  exit 1
fi
echo "render: all overlays OK (kustomize $KUSTOMIZE_VERSION)"
