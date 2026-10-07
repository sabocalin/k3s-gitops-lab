#!/bin/sh
# #27: render every overlay under k8s/overlays/ with the hash-pinned kustomize and check
# the invariants the deploy paths rely on. Same locally (make k8s) and in CI.
#
#   scripts/render-k8s.sh [output dir]     (default: a temporary directory)
#
# Per overlay <name>: exactly one Namespace, named <name>; every other object in that
# namespace (so nothing else cluster-scoped); every container image pinned by digest; pods
# labelled k3s-gitops-lab/deploy-path=<name>; every container with cpu/memory requests and
# limits; exactly one LimitRange and one ResourceQuota (#30); exactly one PodDisruptionBudget
# that selects the Deployment's pods and still allows an eviction (#32); one HPA owning the
# replica count, within the pod quota (#34); Ingresses only on class traefik, to a Service in
# the overlay, on an allowlist of Exact paths (#35), every host under TLS from a known
# ClusterIssuer (#36); a default-deny
# NetworkPolicy plus one letting Traefik's pods (kube-system) reach the app (#33). Across
# overlays: no shared namespace. Then k8s/platform/* (#36): see the end of this file.
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

  namespaces=$(printf '%s\n' "$objects" | jq -r 'select(.kind == "Namespace") | .metadata.name')
  [ "$namespaces" = "$name" ] ||
    problem "$name: expected exactly one Namespace named '$name', got '$(echo "$namespaces" | tr '\n' ' ')'"

  outside=$(printf '%s\n' "$objects" | jq -r --arg ns "$name" \
    'select(.kind != "Namespace" and .metadata.namespace != $ns) | "\(.kind)/\(.metadata.name) (namespace: \(.metadata.namespace // "none"))"')
  [ -z "$outside" ] || problem "$name: objects outside namespace '$name': $outside"

  unpinned=$(printf '%s\n' "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[] | select(.image | test("@sha256:[0-9a-f]{64}$") | not) | .image')
  [ -z "$unpinned" ] || problem "$name: images not pinned by digest: $unpinned"

  # #30: every container declares requests and limits for CPU and memory (the quota
  # counts them; a missing limit would make the node's memory unbounded).
  unbounded=$(printf '%s\n' "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[]
     | select([.resources.requests.cpu, .resources.requests.memory, .resources.limits.cpu, .resources.limits.memory] | any(. == null))
     | .name')
  [ -z "$unbounded" ] || problem "$name: containers without cpu/memory requests and limits: $unbounded"

  # #31: hardened pods: non-root, read-only root FS, no privilege escalation, all caps dropped.
  unhardened=$(printf '%s\n' "$objects" | jq -r \
    'select(.spec.template.spec?) | .spec.template.spec as $p | $p.containers[]
     | select(($p.securityContext.runAsNonRoot != true)
              or (.securityContext.readOnlyRootFilesystem != true)
              or (.securityContext.allowPrivilegeEscalation != false)
              or ((.securityContext.capabilities.drop // []) | index("ALL") | not))
     | .name')
  [ -z "$unhardened" ] || problem "$name: containers missing the #31 securityContext: $unhardened"
  psa=$(printf '%s\n' "$objects" | jq -r 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"')
  [ "$psa" = restricted ] || problem "$name: namespace does not enforce Pod Security 'restricted' (got '$psa')"

  for kind in LimitRange ResourceQuota; do
    count=$(printf '%s\n' "$objects" | jq -r --arg k "$kind" 'select(.kind == $k) | .metadata.name' | wc -l | tr -d ' ')
    [ "$count" = 1 ] || problem "$name: expected exactly one $kind, found $count"
  done

  # #34: one HPA owns the Deployment's replica count, so the Deployment must not set one
  # (every apply would reset the HPA). Its maximum, plus the rollout's surge pod, must fit
  # the ResourceQuota's pod count.
  hpa=$(printf '%s\n' "$objects" | jq -rs '
    ([.[] | select(.kind == "HorizontalPodAutoscaler")]) as $h
    | ([.[] | select(.kind == "Deployment")][0]) as $d
    | ([.[] | select(.kind == "ResourceQuota")][0].spec.hard.pods // "0" | tonumber) as $podquota
    | ($d.spec.strategy.rollingUpdate.maxSurge // 1) as $surge
    | if ($h | length) != 1 then "expected exactly one HorizontalPodAutoscaler, found \($h | length)"
      elif $h[0].spec.scaleTargetRef != {"apiVersion": "apps/v1", "kind": "Deployment", "name": $d.metadata.name} then
        "HorizontalPodAutoscaler targets \($h[0].spec.scaleTargetRef), not Deployment/\($d.metadata.name)"
      elif $d.spec.replicas != null then
        "Deployment sets replicas: \($d.spec.replicas); the HorizontalPodAutoscaler owns it"
      elif ($surge | type) != "number" or $h[0].spec.maxReplicas + $surge > $podquota then
        "HorizontalPodAutoscaler maxReplicas \($h[0].spec.maxReplicas) + maxSurge \($surge) exceeds the ResourceQuota pods (\($podquota))"
      else empty end')
  [ -z "$hpa" ] || problem "$name: $hpa"

  # #32: one PDB, selecting exactly the Deployment's pods, with minAvailable below the
  # HPA's minReplicas (#34). minAvailable >= replicas allows zero evictions: every drain
  # would hang forever.
  pdb=$(printf '%s\n' "$objects" | jq -rs '
    ([.[] | select(.kind == "PodDisruptionBudget")]) as $b
    | ([.[] | select(.kind == "Deployment")][0]) as $d
    | ([.[] | select(.kind == "HorizontalPodAutoscaler")][0].spec.minReplicas // $d.spec.replicas // 1) as $min
    | if ($b | length) != 1 then "expected exactly one PodDisruptionBudget, found \($b | length)"
      elif $b[0].spec.selector.matchLabels != $d.spec.selector.matchLabels then
        "PodDisruptionBudget selector \($b[0].spec.selector.matchLabels) != Deployment selector \($d.spec.selector.matchLabels)"
      elif ($b[0].spec.minAvailable | type) != "number" or $b[0].spec.minAvailable >= $min then
        "PodDisruptionBudget minAvailable \($b[0].spec.minAvailable) must be a number below the minimum replicas (\($min))"
      else empty end')
  [ -z "$pdb" ] || problem "$name: $pdb"

  # #35: Ingresses: class traefik, backends are Services of this overlay, and only
  # allowlisted Exact paths, so /metrics, /ready and /docs never become public by a Prefix.
  ingress=$(printf '%s\n' "$objects" | jq -rs '
    ([.[] | select(.kind == "Service") | .metadata.name]) as $svcs
    | .[] | select(.kind == "Ingress") as $i
    | $i.spec.rules[]?.http.paths[]? as $p
    | if $i.spec.ingressClassName != "traefik" then "Ingress/\($i.metadata.name): ingressClassName \($i.spec.ingressClassName) (want traefik)"
      elif $p.pathType != "Exact" or ([$p.path] | inside(["/", "/health"]) | not) then
        "Ingress/\($i.metadata.name): path \($p.pathType) \($p.path) is not on the allowlist (Exact / or /health)"
      elif ($svcs | index($p.backend.service.name)) == null then
        "Ingress/\($i.metadata.name): backend Service \($p.backend.service.name) is not in this overlay"
      else empty end')
  [ -z "$ingress" ] || problem "$name: $ingress"
  # #36: every Ingress host is covered by spec.tls (no plain-HTTP-only host), and the
  # certificate comes from one of the two ClusterIssuers in k8s/platform/cluster-issuers.
  tls=$(printf '%s\n' "$objects" | jq -r '
    select(.kind == "Ingress")
    | ([.spec.tls[]?.hosts[]?]) as $tls
    | (.metadata.annotations["cert-manager.io/cluster-issuer"] // "none") as $issuer
    | .metadata.name as $n
    | ([.spec.rules[]? | .host // "<no host>"] - $tls | map("Ingress/\($n): host \(.) not in spec.tls")),
      (if ($issuer | IN("letsencrypt-staging", "letsencrypt-prod")) then [] else ["cert-manager.io/cluster-issuer is \($issuer)"] end)
    | .[]')
  [ -z "$tls" ] || problem "$name: $tls"

  # #33: a default deny for every pod, both directions, with no allow rules of its own.
  deny=$(printf '%s\n' "$objects" | jq -r 'select(.kind == "NetworkPolicy")
    | select((.spec.podSelector // {}) == {} and (.spec.policyTypes | index("Ingress") and index("Egress"))
             and .spec.ingress == null and .spec.egress == null) | .metadata.name')
  [ -n "$deny" ] || problem "$name: no default-deny NetworkPolicy (podSelector {}, Ingress and Egress, no rules)"
  # ...and the app reachable from Traefik: one peer with BOTH selectors (AND), so neither a
  # label transformer rewriting the pod selector nor a split into two peers (OR) slips by.
  traefik=$(printf '%s\n' "$objects" | jq -rs '
    ([.[] | select(.kind == "Deployment")][0].spec.selector.matchLabels) as $app
    | [.[] | select(.kind == "NetworkPolicy" and .spec.podSelector.matchLabels == $app)
       | .spec.ingress[]?.from[]?
       | select(.namespaceSelector.matchLabels == {"kubernetes.io/metadata.name": "kube-system"}
                and .podSelector.matchLabels == {"app.kubernetes.io/name": "traefik"})] | length')
  [ "$traefik" -ge 1 ] || problem "$name: no NetworkPolicy lets Traefik (kube-system, app.kubernetes.io/name=traefik) reach the app"

  unlabelled=$(printf '%s\n' "$objects" | jq -r --arg ns "$name" \
    'select(.spec.template.metadata?) | select(.spec.template.metadata.labels["k3s-gitops-lab/deploy-path"] != $ns) | "\(.kind)/\(.metadata.name)"')
  [ -z "$unlabelled" ] || problem "$name: pod templates without deploy-path=$name: $unlabelled"

  case " $seen " in *" $namespaces "*) problem "$name: namespace '$namespaces' already used by another overlay" ;; esac
  seen="$seen $namespaces"

  printf 'ok: %-7s -> %s (%s objects: %s)\n' "$name" "$file" \
    "$(printf '%s\n' "$objects" | wc -l | tr -d ' ')" "$(printf '%s\n' "$objects" | jq -r '.kind' | sort | uniq -c | awk '{printf "%s%s ", $2, ($1 > 1 ? "x" $1 : "")}')"
done

# #36: cluster-wide components (k8s/platform/*), rendered into a subdirectory (CI's job
# summary shows only the overlays; cert-manager alone is about 1 MB). Per component: every
# vendored upstream file still matches vendor/SHA256SUMS; every image, including images
# passed as flags (--*-image=), pinned by digest; every container with cpu/memory requests
# and limits; every Namespace enforcing Pod Security "restricted".
mkdir -p "$out/platform"
for dir in k8s/platform/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  file=$out/platform/$name.yaml
  if [ -f "$dir/vendor/SHA256SUMS" ]; then
    while read -r want vendored; do
      got=$(sha256_of "$dir/vendor/$vendored")
      [ "$got" = "$want" ] || problem "platform/$name: vendor/$vendored sha256 $got, expected $want"
    done <"$dir/vendor/SHA256SUMS"
  fi
  if ! "$KUSTOMIZE" build "$dir" >"$file"; then
    problem "platform/$name: kustomize build failed"
    continue
  fi
  objects=$(yq -o json -I0 '.' "$file")
  unpinned=$(printf '%s\n' "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[]
     | (.image, ((.args // [])[] | select(test("^--[a-z0-9-]*image=")) | sub("^[^=]*="; "")))
     | select(test("@sha256:[0-9a-f]{64}$") | not)')
  [ -z "$unpinned" ] || problem "platform/$name: images not pinned by digest: $unpinned"
  unbounded=$(printf '%s\n' "$objects" | jq -r \
    '.. | objects | select(has("containers")) | .containers[]
     | select([.resources.requests.cpu, .resources.requests.memory, .resources.limits.cpu, .resources.limits.memory] | any(. == null))
     | .name')
  [ -z "$unbounded" ] || problem "platform/$name: containers without cpu/memory requests and limits: $unbounded"
  unrestricted=$(printf '%s\n' "$objects" | jq -r \
    'select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] != "restricted") | .metadata.name')
  [ -z "$unrestricted" ] || problem "platform/$name: namespaces not enforcing Pod Security 'restricted': $unrestricted"
  printf 'ok: platform/%s -> %s (%s objects)\n' "$name" "$file" "$(printf '%s\n' "$objects" | wc -l | tr -d ' ')"
done

if [ "$problems" -gt 0 ]; then
  echo "render: $problems problem(s)" >&2
  exit 1
fi
echo "render: all overlays and platform components OK (kustomize $KUSTOMIZE_VERSION)"
