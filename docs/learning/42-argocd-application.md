# 42 · The pull path: an Argo CD Application with automated sync, prune and selfHeal

> Issue: #42 (4.5) · Phase 4

## What
An Argo CD **Application**, `lab-api-gitops`, keeps the `gitops` namespace equal to
`k8s/overlays/gitops` at the tip of `main`:
- **automated:** a new commit is applied without anyone running anything;
- **prune:** an object removed from git is deleted;
- **selfHeal:** a change made in the cluster is reverted.

It sits in its own **AppProject**, `gitops`: this repository only, the `gitops` namespace only,
nothing cluster-scoped, and four kinds.

## Why
#41 turns every build into a commit, but until now nothing in the cluster acted on it. This
is the "pull" half of the project. The cluster fetches its desired state from git, and no CI
job holds cluster credentials, unlike the push path (#39). Self-heal makes git the
only way to change `gitops`: a `kubectl edit` lasts about two seconds.

The AppProject is needed because the application-controller may do anything in the cluster
(#40). The project is Argo CD's own check before every sync. Core ships no `default` project
(the API server would create one), and that one allows everything anyway.

Alternatives considered:
- **Manual sync** (no `automated`): a human, or CI, decides when. That brings back a step
  between merge and deploy, and nothing reverts drift.
- **`automated` without `selfHeal`**: syncs only when `main` moves. Drift is shown
  (OutOfSync) and left in place; see the negative control below.
- **`targetRevision` pinned to a commit**: every bump would then need a second edit. The
  bot already moves `main`, and `main` is protected (#6).
- **A git webhook instead of polling**: core has no API server to receive it, and the node
  has no public endpoint for Argo CD. Polling is every 3 minutes; #44 measures the total
  delay.
- **A narrower ClusterRole for the controller**: possible later. It means editing
  upstream's RBAC, and the AppProject is the standard first fence.

## How it works
```
git: main ──(poll every 180 s + jitter)──▶ repo-server: clone, kustomize build k8s/overlays/gitops
                                                 │ desired manifests (cached in redis)
application-controller ◀────────────────────────┘
  informers watch the live objects in gitops ──▶ any change triggers a compare at once
  compare desired vs live ─▶ Synced | OutOfSync
  OutOfSync and (new revision, or selfHeal) ─▶ project check ─▶ apply (kubectl apply)
  objects carrying this app's tracking-id but no longer in git ─▶ prune (delete)
```
- **Tracking.** Argo CD v3 marks every object it applies with an annotation:
  `argocd.argoproj.io/tracking-id: lab-api-gitops:apps/Deployment:gitops/lab-api`. That
  annotation is what makes an object "part of the app". Prune deletes only annotated objects
  that git no longer has. The namespace's guardrails (LimitRange, ResourceQuota,
  NetworkPolicies, applied by an admin from `k8s/namespaces/gitops`) carry no annotation, so
  they are never touched.
- **Why drift is reverted in seconds while git takes minutes.** The controller keeps a watch
  (an informer cache) on every resource type it manages, so a live change reaches it
  immediately. Git has no such push channel here and is polled.
- **What counts as drift.** Fields that git sets. `replicas` is not in git (the HPA owns
  it, #34), so scaling the Deployment is not drift. An annotation someone adds is not
  drift either. Changing the image, a limit or `revisionHistoryLimit` is drift.
- **The project check runs before anything is applied.** Each sync task (one per object) is
  validated against the project: destination namespace, group and kind. If any task fails,
  the whole sync fails and nothing is applied.

## Implementation
- `k8s/platform/argocd-apps/` (new): applied by an admin after `../argocd`, like
  `cluster-issuers` after `cert-manager` (these objects are instances of Argo CD's CRDs).
  `namespace: argocd`, because core only watches its own namespace. From #43 a root
  Application syncs this directory.
- `appproject-gitops.yaml`:
  - `sourceRepos`: exactly `https://github.com/sabocalin/k3s-gitops-lab.git`. The repository
    is public, so there are no repository credentials.
  - `destinations`: `https://kubernetes.default.svc` (the cluster Argo CD runs in),
    namespace `gitops`.
  - `clusterResourceWhitelist: []`: nothing cluster-scoped. The Namespace stays admin-owned
    (#38).
  - `namespaceResourceWhitelist`: Deployment, Service, PodDisruptionBudget,
    HorizontalPodAutoscaler. That is what the overlay renders, and the same set the push
    deployer's Role may write. No NetworkPolicy, quota, RBAC or Secrets.
- `application-lab-api-gitops.yaml`:
  - `source`: `main`, path `k8s/overlays/gitops`.
  - `automated: {prune: true, selfHeal: true}`.
  - `CreateNamespace=false`: the default, written down because the namespace is admin-owned.
  - `FailOnSharedResource=true`: refuse to take over an object another Application tracks
    (relevant once #43 adds more Applications).
  - `retry` (limit 5, backoff 10 s ×2 up to 3 min): without it, Argo CD does not retry a
    failed automated sync of the same commit.
  - **No `resources-finalizer`**: deleting the Application leaves the workload running.
    Cascade delete is one `kubectl delete` away from removing `gitops` entirely; it's
    reconsidered in #43.
- `scripts/render-k8s.sh` adds a check per Application under `k8s/platform`:
  - the Application uses this repository, `main` and a path under `k8s/overlays/`, deploys
    to the namespace named after the overlay, and has prune and selfHeal both on;
  - its AppProject is defined in the repo, with exactly this repository, exactly that
    namespace, nothing cluster-scoped and no wildcards;
  - the whitelist equals the kinds the overlay renders, in both directions. A new kind in
    the overlay fails CI, instead of failing the sync in the cluster.
- Argo CD's bundled kustomize is v5.8.1, the version `scripts/lib/tools.sh` pins, so CI
  renders what Argo CD renders.

## Verification
Applied after `kubectl apply -k k8s/platform/argocd-apps --dry-run=server` (2 objects
created).

| Check | Result |
|---|---|
| First sync | `Synced/Healthy` 33 s after the apply, revision `4db8663` (the bot's merge, #41) |
| Objects | Deployment, Service, PDB, HPA, each with the tracking-id annotation |
| Pods | 3/3, all `lab-api@sha256:9186280a…`, the digest in `k8s/overlays/gitops/image` |
| `/health` (port-forward to the Service) | `{"status":"ok"}`, `/` 200 |
| **Done when:** `kubectl edit deploy/lab-api`, `revisionHistoryLimit` 5 → 20 | back to 5 in **1.7 s**, by an automated sync |
| `kubectl edit`: image → the push digest `1b612533…` | back in **2 s**. One surge pod with the patched image started and was deleted 1 s later; the 3 running pods were never touched (`maxUnavailable: 0`) |
| Node after the sync | 1819 Mi available, swap 0, memory pressure (PSI) 0; the 3 pods use about 36 Mi each |

Negative controls:

| Test | Result |
|---|---|
| `selfHeal: false` (patched in the cluster), same edit | OutOfSync after 5 s, **still 20 after 90 s**. Detected, not reverted: automated sync alone only acts when `main` moves |
| Re-apply the Application from git (`selfHeal: true`) | the waiting drift reverted in 2 s |
| Test Application in project `gitops`, destination `push` | refused: `InvalidSpecError: … namespace 'push' do not match any of the allowed destinations in project 'gitops'` |
| Test Application in project `gitops`, path `k8s/overlays/push`, destination `gitops` (the objects name `push` themselves), one manual sync | `Failed: one or more synchronization tasks are not valid`: namespace `push` not permitted; Ingress and Middleware kinds not permitted. Push objects unchanged (same resourceVersions, no tracking-id) |
| Service `tracked-stray` with this app's tracking-id | pruned within 1 s |
| Service `untracked-stray`, no annotation; the 5 guardrails | still there 30 s later (then deleted by hand) |
| `make k8s` with 7 broken copies: destination `push`, HPA missing from the whitelist, NetworkPolicy added to it, selfHeal off, a fork's repoURL, a cluster-wide wildcard, project `default` | each one reported |

## Gotchas
- **Self-heal can't fix what git doesn't say.** `replicas`, extra annotations and anything
  else absent from the manifests is invisible to the compare. That's also why the HPA and
  Argo CD don't fight over the replica count.
- **The Application itself can drift.** `kubectl patch application … selfHeal:false` stuck
  until the file was re-applied. Nothing reverts the Application until #43 puts it under a
  root app.
- **An edit to the pod template still starts a pod.** Self-heal is fast, but not instant.
  The Deployment controller acts first, so the patched image did run, briefly, in a surge
  pod. The guarantee is "reverted within seconds", not "never runs".
- **Self-heal syncs don't appear in `.status.history`.** History only records a new
  revision; the revert shows in `.status.operationState` (`initiatedBy.automated`).
- **Kinds outside the project show `Unknown`**, not an error, until a sync is attempted.
  Argo CD doesn't even read their live state.
- **A test pod in `gitops` needs a numeric user.** `curlimages/curl` runs as `curl_user`,
  and `runAsNonRoot` rejects a non-numeric user. Use port-forward to reach the Service.
- **zsh:** `path` is tied to `$PATH`. A loop variable named `path` empties the command search
  path.

## Further reading
- [Argo CD: automated sync policy (prune, selfHeal)](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [Argo CD: projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [Argo CD: sync options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Argo CD: resource tracking](https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/)
- [Argo CD: Application deletion and finalizers](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/)
