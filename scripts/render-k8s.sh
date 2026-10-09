#!/bin/sh
# #27: render every overlay under k8s/overlays/ with the hash-pinned kustomize and check
# the invariants the deploy paths rely on. Same locally (make k8s) and in CI.
#
#   scripts/render-k8s.sh [output dir]     (default: a temporary directory)
#
# #38: each overlay <name> is rendered together with k8s/namespaces/<name> (the Namespace and
# its guardrails, applied by an admin) and the checks below run on both. On top: the split
# holds (guardrail and RBAC kinds only in k8s/namespaces/<name>, never in the overlay, so a
# deployer never applies them), and where a deployer Role exists, it covers every kind the
# overlay contains.
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
# overlays: no shared namespace. Then k8s/platform/* (#36) and the Argo CD Applications
# and AppProjects (#42, #43): see the end of this file.
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
  nsfile=$out/$name-namespace.yaml
  if ! "$KUSTOMIZE" build "$dir" >"$file"; then
    problem "$name: kustomize build failed"
    continue
  fi
  if ! "$KUSTOMIZE" build "k8s/namespaces/$name" >"$nsfile"; then
    problem "$name: kustomize build of k8s/namespaces/$name failed (every overlay needs one)"
    continue
  fi
  # One JSON object per line, for jq. app: what the deployer applies; ns: the admin's part.
  app=$(yq -o json -I0 '.' "$file")
  ns=$(yq -o json -I0 '.' "$nsfile")
  objects=$(printf '%s\n%s\n' "$ns" "$app")

  # #38: the ownership split. Guardrails and identities are never part of what a deployer
  # applies; the namespace part holds nothing else.
  guarded='["Namespace", "LimitRange", "ResourceQuota", "NetworkPolicy", "ServiceAccount", "Role", "RoleBinding", "Secret"]'
  leaked=$(printf '%s\n' "$app" | jq -r --argjson g "$guarded" 'select(.kind | IN($g[])) | "\(.kind)/\(.metadata.name)"' | paste -sd, -)
  [ -z "$leaked" ] || problem "$name: guardrail/identity objects in k8s/overlays/$name (belong in k8s/namespaces/$name): $leaked"
  stray=$(printf '%s\n' "$ns" | jq -r --argjson g "$guarded" 'select(.kind | IN($g[]) | not) | "\(.kind)/\(.metadata.name)"' | paste -sd, -)
  [ -z "$stray" ] || problem "$name: app objects in k8s/namespaces/$name (belong in k8s/overlays/$name): $stray"

  # #38: if a deployer Role exists, it can get, create and patch every kind in the overlay
  # (kubectl apply needs exactly those), so a deploy never dies on a missing permission.
  # Resource names from kinds: lowercase plural (Ingress -> ingresses).
  uncovered=$(printf '%s\n%s\n' "$ns" "$app" | jq -rs '
    ([.[] | select(.kind == "Role" and .metadata.name == "github-deployer")][0]) as $role
    | if $role == null then empty else
        .[] | select(.kind | IN("Namespace", "LimitRange", "ResourceQuota", "NetworkPolicy", "ServiceAccount", "Role", "RoleBinding") | not)
        | (.apiVersion | if test("/") then split("/")[0] else "" end) as $group
        | (.kind | ascii_downcase | if endswith("s") then . + "es" elif endswith("y") then .[:-1] + "ies" else . + "s" end) as $res
        | select([$role.rules[] | select((.apiGroups | index($group)) and (.resources | index($res)))
                  | .verbs] | add // [] | (index("get") and index("create") and index("patch")) | not)
        | "\(.kind) (\($group)/\($res))"
      end' | paste -sd, -)
  [ -z "$uncovered" ] || problem "$name: Role github-deployer cannot get/create/patch: $uncovered"

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
# and limits; every Namespace enforcing Pod Security "restricted", unless it carries a
# written reason in the annotation k3s-gitops-lab/pod-security-exception (#54), and even
# then warning on "restricted", so violations stay visible.
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
    'select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] != "restricted")
     | select((.metadata.annotations["k3s-gitops-lab/pod-security-exception"] // "") == ""
              or .metadata.labels["pod-security.kubernetes.io/warn"] != "restricted")
     | .metadata.name')
  [ -z "$unrestricted" ] || problem "platform/$name: namespaces not enforcing Pod Security 'restricted' (and no k3s-gitops-lab/pod-security-exception reason with warn=restricted): $unrestricted"
  printf '%s\n' "$objects" | jq -r --arg c "$name" \
    'select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] != "restricted")
     | "note: platform/\($c): namespace \(.metadata.name) enforces \(.metadata.labels["pod-security.kubernetes.io/enforce"]): \(.metadata.annotations["k3s-gitops-lab/pod-security-exception"] // "")"'
  printf 'ok: platform/%s -> %s (%s objects)\n' "$name" "$file" "$(printf '%s\n' "$objects" | wc -l | tr -d ' ')"
done

# #42, #43: Argo CD Applications and AppProjects defined under k8s/platform.
# Per Application: from this repository at main, automated prune and selfHeal on, a path
# that is an overlay (k8s/overlays/<name>, deployed into namespace <name>) or a platform
# component (k8s/platform/<name>), in an AppProject defined here.
# Per AppProject, against everything its Applications render (a kind is cluster-scoped
# when the rendered object has no namespace): sourceRepos is exactly this repository;
# destinations are exactly the namespaces used, on this cluster; clusterResourceWhitelist
# and namespaceResourceWhitelist equal the kinds used, no more, no fewer, no wildcards.
# A new kind or namespace in a component is then a failed check and a reviewed project
# change, instead of a sync that fails in the cluster, or a fence wider than needed.
repo_url=https://github.com/sabocalin/k3s-gitops-lab.git
argo=$(yq -o json -I0 '.' "$out"/platform/*.yaml | jq -c 'select(.kind == "Application" or .kind == "AppProject")')
used=$(mktemp)
for app in $(printf '%s\n' "$argo" | jq -r 'select(.kind == "Application") | .metadata.name'); do
  spec=$(printf '%s\n' "$argo" | jq -c --arg a "$app" 'select(.kind == "Application" and .metadata.name == $a) | .spec')
  src=$(printf '%s' "$spec" | jq -r '.source.path')
  case $src in
    k8s/overlays/*) rendered=$out/${src#k8s/overlays/}.yaml; want_ns=${src#k8s/overlays/} ;;
    k8s/platform/*) rendered=$out/platform/${src#k8s/platform/}.yaml; want_ns="" ;;
    *) problem "Application/$app: path $src is not k8s/overlays/<name> or k8s/platform/<name>"; continue ;;
  esac
  if [ ! -f "$rendered" ]; then
    problem "Application/$app: $src was not rendered"
    continue
  fi
  wrong=$(jq -rn --argjson s "$spec" --arg repo "$repo_url" --arg ns "$want_ns" '
    [ (if $s.source.repoURL != $repo then "repoURL is not \($repo)" else empty end),
      (if $s.source.targetRevision != "main" then "targetRevision is not main" else empty end),
      (if $s.destination.server != "https://kubernetes.default.svc" then "destination is not this cluster" else empty end),
      (if $ns != "" and $s.destination.namespace != $ns then "destination namespace is not \($ns)" else empty end),
      (if [$s.syncPolicy.automated.prune, $s.syncPolicy.automated.selfHeal] != [true, true] then "automated prune and selfHeal are not both on" else empty end)
    ] | join("; ")')
  [ -z "$wrong" ] || problem "Application/$app: $wrong"
  # What this Application deploys, as {project, app, group, kind, ns}: one line per kind.
  # The destination namespace counts as used even with no object in it (cluster-issuers).
  yq -o json -I0 '.' "$rendered" | jq -c --argjson s "$spec" --arg a "$app" '
    {project: $s.project, app: $a,
     group: (.apiVersion | if contains("/") then split("/")[0] else "" end), kind,
     ns: (.metadata.namespace // "")}' >>"$used"
  jq -cn --argjson s "$spec" --arg a "$app" '{project: $s.project, app: $a, ns: $s.destination.namespace}' >>"$used"
done
for project in $(jq -r '.project' "$used" | sort -u); do
  spec=$(printf '%s\n' "$argo" | jq -c --arg p "$project" 'select(.kind == "AppProject" and .metadata.name == $p) | .spec')
  if [ -z "$spec" ]; then
    problem "AppProject/$project: used by $(jq -r --arg p "$project" 'select(.project == $p) | .app' "$used" | sort -u | paste -sd, -) but not defined in k8s/platform"
    continue
  fi
  wrong=$(jq -rs --argjson p "$spec" --arg repo "$repo_url" --arg name "$project" '
    map(select(.project == $name)) as $u
    | def set(f): map(f) | unique;
      def gk: {group, kind};
      def show: map(if type == "object" then "\(.group)/\(.kind)" else . end) | join(", ");
      def cmp(what; have; allowed):
        [ (if (have - allowed) != [] then "\(what) missing: \((have - allowed) | show)" else empty end),
          (if (allowed - have) != [] then "\(what) not needed: \((allowed - have) | show)" else empty end) ];
    ($u | map(select(.kind != null))) as $objs
    | [ (if $p.sourceRepos != [$repo] then "sourceRepos is not exactly [\($repo)]" else empty end),
        (if ($p.destinations | any(.server != "https://kubernetes.default.svc")) then "a destination is not this cluster" else empty end),
        (if ([$p.clusterResourceWhitelist[]?, $p.namespaceResourceWhitelist[]?] | any(.group == "*" or .kind == "*"))
           or ($p.destinations | any(.namespace == "*")) then "a wildcard" else empty end),
        cmp("destinations"; $u | map(select(.ns != "")) | set(.ns); $p.destinations // [] | set(.namespace)),
        cmp("clusterResourceWhitelist"; $objs | map(select(.ns == "")) | set(gk); $p.clusterResourceWhitelist // [] | set(gk)),
        cmp("namespaceResourceWhitelist"; $objs | map(select(.ns != "")) | set(gk); $p.namespaceResourceWhitelist // [] | set(gk))
      ] | flatten | join("; ")' "$used")
  if [ -n "$wrong" ]; then
    problem "AppProject/$project: $wrong"
  else
    printf 'ok: AppProject/%s -> %s\n' "$project" "$(jq -r --arg p "$project" 'select(.project == $p) | .app' "$used" | sort -u | paste -sd, -)"
  fi
done
rm -f "$used"

if [ "$problems" -gt 0 ]; then
  echo "render: $problems problem(s)" >&2
  exit 1
fi
echo "render: all overlays and platform components OK (kustomize $KUSTOMIZE_VERSION)"
