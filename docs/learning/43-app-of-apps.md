# 43 · App-of-apps: Argo CD manages cert-manager, the issuers, and itself

> Issue: #43 (4.6) · Phase 4

## What
A **root** Application syncs `k8s/platform/argocd-apps`, which holds every Application and
AppProject, the root included. Three new child Applications put the cluster-wide components
under Argo CD:
- `argocd`: Argo CD itself;
- `cert-manager`;
- `cluster-issuers`: the two Let's Encrypt ClusterIssuers.

`lab-api-gitops` (#42) moves under the root too. A new AppProject, `platform`, holds them all.

## Why
Until now cert-manager and Argo CD were applied once with `kubectl` and nothing watched
them: a deleted Deployment stayed deleted, and an upgrade was a manual apply. #42 also
left two gaps:
- nothing reverted a change to an Application object itself;
- a new or changed Application needed a manual `kubectl apply`.

With a root app, `main` describes the whole platform, and a rebuild (#52) needs only two
manual steps: install Argo CD, then apply this directory once.

Alternatives considered:
- **ApplicationSet** (one Application per directory, from a generator): less repetition,
  but each component here needs different sync options (server-side apply, a longer
  retry), so a template would mostly be overrides. Also, the generated Applications can't be
  reviewed as files.
- **Helm chart of Applications** (the classic app-of-apps form): templating that saves
  nothing at five Applications, and the project renders everything with Kustomize.
- **Leave Argo CD out (managed by hand or by Ansible), Argo CD manages the rest**: avoids
  the self-management loop, but leaves upgrades as an untracked manual step. Argo CD
  documents managing itself as a supported setup.
- **One Application for all platform components**: one sync for everything. A failure in
  one (the ClusterIssuers before cert-manager is up) would block the others, and health
  would be reported per bundle, not per component.

## How it works
```
kubectl apply -k k8s/platform/argocd-apps        (once per cluster, the bootstrap)
root ──syncs main:k8s/platform/argocd-apps──▶ wave -1: AppProject platform, AppProject gitops
                                              wave 0:  Application root (itself), argocd,
                                                       cert-manager, cluster-issuers,
                                                       lab-api-gitops
argocd          ──▶ k8s/platform/argocd          (server-side apply)
cert-manager    ──▶ k8s/platform/cert-manager
cluster-issuers ──▶ k8s/platform/cluster-issuers (retries until cert-manager's webhook answers)
lab-api-gitops  ──▶ k8s/overlays/gitops          (project gitops, #42)
```
- **The root manages itself.** `application-root.yaml` is in the directory the root syncs,
  so a change to it merged on `main` is applied by the root itself. A `kubectl edit` of any
  Application is drift in the root, reverted like a Deployment edit in #42.
- **Sync waves** order the objects inside one sync. AppProjects go in wave -1 because an
  Application whose project doesn't exist is rejected. Waves don't make one Application
  wait for another to become healthy (Argo CD stopped assessing child Application health in
  1.8). Hence the retry on `cluster-issuers` instead of a wave.
- **Adoption.** Everything already existed, applied by `kubectl`. An Argo CD diff showed
  exactly one difference per object: the missing `argocd.argoproj.io/tracking-id`
  annotation (35 objects across the three apps). The first sync added it: no Deployment
  changed, no pod restarted, and no new ReplicaSet appeared.
- **Self-management.** The application-controller applies its own StatefulSet. If a sync
  changes the controller's pod, Kubernetes replaces the pod, and the new one picks up
  where the sync left off (sync state lives in the Application object, not in memory).
- **The caBundle question.** cert-manager's cainjector writes the webhook's CA into
  `caBundle` at runtime, through server-side apply (field manager
  `cert-manager-cainjector`). The manifests in git have no `caBundle` key at all, so
  client-side apply's three-way merge leaves it alone, and Argo CD's diff ignores fields
  that neither git nor the last apply set. Measured: Synced, caBundle still 896 bytes after
  syncing. No `ignoreDifferences` was needed. It would be if git set `caBundle: ""`, as
  some charts do.

## Implementation
- `k8s/platform/argocd-apps/`:
  - `appproject-platform.yaml`: this repository only, namespaces `argocd`, `cert-manager`
    and `kube-system` (cert-manager's leader-election Roles), 7 cluster-scoped kinds and
    11 namespaced kinds, exactly what the paths render. It can create ClusterRoles and
    bindings, so it is as powerful as cluster-admin. The real fence is upstream: one
    repository, its protected `main` (#6), and render-k8s.sh keeping the kind lists exact.
  - `application-root.yaml`: `main`, path `k8s/platform/argocd-apps`, project `platform`.
  - `application-argocd.yaml`: `ServerSideApply=true`, because the ApplicationSet CRD
    (1.44 MB) doesn't fit client-side apply's 256 KiB annotation (#40).
  - `application-cert-manager.yaml`: default client-side apply, as it was applied before.
  - `application-cluster-issuers.yaml`: `SkipDryRunOnMissingResource=true` and 10 retries,
    for a fresh cluster where cert-manager isn't up yet. That path is untested until #52.
  - All: automated prune and selfHeal, `FailOnSharedResource=true`, retry with backoff,
    **no resources-finalizer**. Deleting an Application, even the root, leaves the workload
    running. A finalizer on the root would make one `kubectl delete` remove Argo CD and
    cert-manager.
  - `appproject-gitops.yaml`: sync wave -1.
- `k8s/platform/{argocd,cert-manager}/kustomization.yaml`: every CRD and Namespace gets
  `argocd.argoproj.io/sync-options: Prune=false`. If one ever disappears from git, Argo CD
  leaves it in place. Deleting a CRD deletes every object of that kind (every Application,
  every Certificate), and deleting a Namespace deletes everything in it.
- `scripts/render-k8s.sh`: the #42 check, generalised.
  - Per Application: this repository, `main`, this cluster, prune and selfHeal on, and a
    path that is `k8s/overlays/<name>` (destination namespace `<name>`) or
    `k8s/platform/<name>`.
  - Per AppProject, against the union of what its Applications render:
    - `sourceRepos` is exactly this repository;
    - destinations equal the namespaces used;
    - `clusterResourceWhitelist` equals the cluster-scoped kinds used, and
      `namespaceResourceWhitelist` the namespaced ones;
    - no wildcards.
- Comments in the platform and namespace kustomizations no longer say "applied by hand".

## Verification
Before the merge, `root` can't be tested: it follows `main`, which doesn't have these files
yet. The child Applications were created first **without** automated sync, so Argo CD
reported drift without acting on it. They were switched on after that. Their sources are
paths that already exist on `main`.

| Check | Result |
|---|---|
| `kubectl apply -k k8s/platform/argocd-apps --dry-run=server` | AppProject `platform` and 4 Applications created; AppProject `gitops` configured (the wave annotation); `lab-api-gitops` unchanged |
| Manual mode, `argocd app diff --core` (CLI v3.5.3, checksum-verified) | `cert-manager`: only the tracking annotation on the Namespace. `cluster-issuers`: the same on both ClusterIssuers. `argocd`: the same on 32 objects. No field differences |
| Automated: cert-manager, cluster-issuers | Synced/Healthy about 17 s after the apply. No new ReplicaSet, no pod restarted, webhook `caBundle` still 896 bytes, both issuers Ready |
| Automated: argocd (manages itself) | Synced/Healthy about 22 s after the apply. No Argo CD pod restarted; `argocd-controller` now co-owns the fields (server-side apply), next to `kubectl` |
| **Done when:** `kubectl delete deploy cert-manager -n cert-manager` | **recreated in 2.2 s** (new uid), by an automated sync, with this repo's patches (digest-pinned image and solver flag, resource limits). The certificate in `push` stayed Ready |
| Node afterwards | 1695 Mi available, memory pressure 0 |

Negative controls:

| Test | Result |
|---|---|
| `selfHeal: false` on cert-manager, same delete | still NotFound after 10, 30 and 60 s; the app is OutOfSync. Re-applying the Application from git recreated the Deployment in 1 s |
| Two stray Namespaces carrying cert-manager's tracking id, one with `Prune=false` | without the annotation: pruned (Terminating within 20 s). With it: still Active, flagged `requiresPruning`, app stays OutOfSync until it's deleted by hand |
| `make k8s` with 8 broken copies: StatefulSet missing from `platform`, an unneeded Ingress added, `kube-system` destination missing, lab-api destination `push`, cert-manager in an undefined project, selfHeal off on `argocd`, a `*` destination, an Application path under `k8s/namespaces` | each one reported |

After the merge (to record with #44):
- bootstrap the root with `kubectl apply -k k8s/platform/argocd-apps`;
- the root is Synced and every Application carries the root's tracking id;
- the `Prune=false` annotations reach the 9 CRDs and both Namespaces;
- a `kubectl patch` turning off `lab-api-gitops`'s selfHeal is reverted by the root.

## Gotchas
- **App health ignored a missing Deployment.** With selfHeal off and the cert-manager
  Deployment deleted, the app showed `OutOfSync/Healthy`: the resource had no health
  (null), and missing resources don't lower the app's health. Watch sync status, not just
  health.
- **`Prune=false` makes an app permanently OutOfSync** while the object exists. That's
  the price of the guard: removing a CRD or Namespace is a manual, deliberate step.
- **A child Application needs a destination namespace even if it deploys nothing
  namespaced** (`cluster-issuers`). Argo CD checks the destination against the project.
- **Argo CD CLI in core mode reads `argocd-cm` from the kubeconfig context's namespace.**
  Pointing it at a context with `namespace: argocd` fixes `configmap "argocd-cm" not
  found`. It was done with a credential-free kubeconfig overlay (only a context, reusing
  the lab file's cluster and user), so the lab kubeconfig wasn't edited.
- **Tracking id for cluster-scoped objects** uses the Application's destination namespace:
  `cert-manager:/Namespace:cert-manager/cert-manager`.
- **Not yet under Argo CD:** `k8s/namespaces/{push,gitops}` (namespaces, guardrails,
  the push deployer's RBAC) are still admin-applied, and so is the Argo CD install the very
  first time. #52 (rebuild from zero) decides whether the namespaces join `platform`.

## Further reading
- [Argo CD: cluster bootstrapping (app of apps)](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Argo CD: manage Argo CD using Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#manage-argo-cd-using-argo-cd)
- [Argo CD: sync phases and waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [Argo CD: sync options (Prune=false, ServerSideApply, SkipDryRunOnMissingResource)](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Argo CD: diffing customization (ignoreDifferences)](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
