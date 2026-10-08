# 40 · Argo CD core install (and why the node is now a t4g.medium)

> Issue: #40 (4.3) · Phase 4

## What
**Argo CD "core"** runs in namespace `argocd`: application-controller, repo-server, redis
and applicationset-controller. That's the GitOps engine without its API server, web UI or
SSO (Dex). It pulls desired state from git and applies it; #42 gives it its first
Application. Installing it on the 2 GiB `t4g.small` failed the memory gate from #47
(heavy swapping, about 30% memory stall), so the node is now a **`t4g.medium`** (4 GiB).

## Why
Phase 4 compares two delivery models. In the push model (#39), CI holds a credential into
the cluster and applies changes. In the pull model, an agent inside the cluster watches
git and converges to it. Nothing outside needs cluster credentials, and drift (a manual
`kubectl edit`) gets reverted. Argo CD is that agent.

Alternatives considered:
- **Full Argo CD install** (API server, UI, Dex): a web UI and SSO, about 150–200 Mi more,
  and an API server to secure. Core is driven with `kubectl` and Application objects.
- **Flux**: the other mainstream GitOps controller, lighter and CRD-driven. The project
  plan names Argo CD; the concepts (pull, reconcile, self-heal) are the same.
- **Helm chart**: the usual install. The upstream manifest is vendored and patched with
  Kustomize instead, like cert-manager (#36), so one toolchain renders everything.

## How it works
- **application-controller** (StatefulSet): for each Application, compares the live objects
  with what git renders, reports Synced/OutOfSync and Healthy, and syncs if told to.
  Cluster-wide permissions (`ClusterRole argocd-application-controller`: everything).
  AppProjects (#42) are what restrict it per application.
- **repo-server**: clones the repository and runs `kustomize build`; the controller never
  touches git itself.
- **redis**: a cache for rendered manifests and app state.
- **applicationset-controller**: generates Applications from templates (one per directory,
  per cluster…). Not used yet.
- Upstream ships a NetworkPolicy per component, so only the controller reaches
  repo-server and redis.

## Implementation
- `k8s/platform/argocd/vendor/argocd-core-install-v3.5.3.yaml`: upstream
  `manifests/core-install.yaml` at the **v3.5.3** tag's commit
  `c9c369efcc5b2a0bd720803f8d14a1c3eaddf579`, unmodified (the install manifests are not
  release assets, so the commit is the provenance). v3.5.4 was a day old (7-day cooldown).
  sha256 in `vendor/SHA256SUMS`, checked by `render-k8s.sh`.
- `k8s/platform/argocd/namespace.yaml`: upstream expects the namespace to exist; Pod
  Security **`restricted`**. Argo CD's pods already comply (no warnings).
- `kustomization.yaml`:
  - `namespace: argocd`;
  - images by digest: `quay.io/argoproj/argocd` and redis;
  - requests and limits for all four containers (upstream sets none), sized from the
    measurements below.
- **Image verification:**
  - `quay.io/argoproj/argocd@sha256:dd3f47d5…` is keyless-signed. `cosign verify` with
    issuer `token.actions.githubusercontent.com` and identity
    `…/argo-cd/.github/workflows/image-reuse.yaml@refs/tags/v3.5.3` passes (Rekor
    included). **Negative:** the same digest against identity `…@refs/tags/v3.5.4` →
    `no matching CertificateIdentity`.
  - redis (`public.ecr.aws/docker/library/redis@sha256:08ad0b1d…`) is a Docker Official
    Image with no cosign signature to check. It's pinned by digest, and Docker Hub and
    ECR Public serve the same index digest.
- **Applied with server-side apply:** `kubectl apply -k k8s/platform/argocd --server-side
  --force-conflicts`. Argo CD's documented way, for the reason in Gotchas.
- `terraform/instance/variables.tf`: `instance_type` default **`t4g.medium`**. Applied from
  a saved plan: `aws_instance.node will be updated in-place`, 0 added, 0 destroyed.
  Modifications complete after 24 s (the node was stopped). Re-plan: only the outputs
  (public IP) differ.
- `README.md`: diagram and cost table.

## Verification
**Gate A on `t4g.small` (2 GiB) — failed.** Before: 543 Mi available, 121 Mi swap, pressure
about 0. With Argo CD running (plus the failed applies of its 1.44 MB CRD):

| Measure | Gate A | Measured |
|---|---|---|
| `MemAvailable` | ≥ 300 Mi | **297 Mi** |
| Swap in use | ≤ 300 Mi | **762–853 Mi** |
| PSI memory `some avg300` | < 1 | **29.8** (`full` 27.5: all tasks stalled 27% of the time) |
| `k3s-server` RSS | | 826 Mi (707 before) |
| Symptoms | | metrics-server lost its endpoints, `Slow SQL` in kine, API calls timing out |

Argo CD was scaled to 0 at once (the app kept answering, `https://…/health` 200 in 0.46 s);
over the next two minutes memory stall fell from 33% to 17% and swap from 853 to 664 Mi.
Decision, per #47's gate: resize.

**On `t4g.medium` (4 GiB)**, before Argo CD: 3824 Mi total, 2411 Mi available, swap 0.
Argo CD then applied in one server-side apply (all 3 CRDs), the three Deployments scaled
back to 1, all four pods Running, no `no matches for kind` errors.

**Gate A on `t4g.medium`, 15 minutes later — passed:**

| Measure | Gate A | Measured |
|---|---|---|
| `MemAvailable` | ≥ 300 Mi | **2250 Mi** |
| Swap in use | ≤ 300 Mi | **0** |
| PSI memory `some`/`full avg300` | < 1 | **0.00 / 0.00** |
| OOM kills (`dmesg`, `OOMKilled` pods) | none | **none** |

`kubectl top pods -n argocd` (the issue's "done when"):

| Pod | CPU | Memory |
|---|---|---|
| argocd-application-controller-0 | 1m | **114Mi** |
| argocd-redis | 6m | 26Mi |
| argocd-repo-server | 1m | 24Mi |
| argocd-applicationset-controller | 1m | 18Mi |
| **Total** | | **182Mi** |

Node: `kubectl top node` 2291Mi (59%); `k3s-server` 863 Mi RSS, containerd 175 Mi;
requests 700Mi (18%), limits 1930Mi (50%). Per namespace (working set): kube-system 297,
cert-manager 189, argocd 182, push 115 Mi. kube-system and cert-manager read higher than on
the 2 GiB node (about 105 and 66 Mi): the working set includes page cache charged to each
container, and with spare RAM the kernel keeps more of it. Compare totals within one node
size, not across.

**Gate B** (before Alloy #48 / External Secrets #54: available ≥ estimate + 200 Mi): 2250 Mi
against at most 250 + 200 Mi. Plenty.

Render checks: `platform/argocd` passes (vendored hash, both images by digest, requests and
limits on every container, namespace `restricted`). The controller runs without errors;
upstream's four NetworkPolicies are in place.

## Gotchas
- **The ApplicationSet CRD (1.44 MB) can't be applied client-side.** `kubectl apply` stores
  the whole object in the `last-applied-configuration` annotation, and annotations are
  limited to 256 KiB: `metadata.annotations: Too long`. Everything else was created, so
  the applicationset-controller ran and logged `no matches for kind "ApplicationSet"` every
  10 s. Server-side apply tracks ownership in `managedFields` instead, with no annotation.
- **Big CRDs cost API-server memory, not pod memory.** The API server keeps every CRD's
  OpenAPI schema in memory, and Argo CD's three CRDs are about 1.84 MB of YAML (1.44 MB of it ApplicationSet). `k3s-server`
  went from 707 to 826 Mi while the pods themselves stayed small. Pod-level `kubectl top`
  doesn't show this.
- **A scale-to-0 survives re-apply** when the manifest doesn't set `replicas`. Three of the
  four upstream workloads don't; the API server only defaults it to 1 at creation. After
  scaling them to 0 under memory pressure, a full server-side re-apply left them at 0
  until `kubectl scale --replicas=1`.
- **No `default` AppProject in core.** Argo CD's API server creates it; core has none.
  #42 must define its own AppProject (better anyway: restrict it to `gitops`).
- `server.secretkey is missing … failed to create webhook handler` in the
  applicationset-controller log: that key is also created by the API server. It only
  affects the git webhook receiver, which isn't used (Argo CD polls git).
- **Under memory thrash, symptoms look like network problems.** The first server-side apply
  failed with `stream error … INTERNAL_ERROR`, and a smaller one timed out. Both were the
  API server stalled on memory; on 4 GiB the same full apply went through first try.

## Further reading
- [Argo CD: core installation](https://argo-cd.readthedocs.io/en/stable/operator-manual/core/)
- [Argo CD: installation (server-side apply)](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/)
- [Kubernetes: server-side apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- [Argo CD: verifying signed images](https://argo-cd.readthedocs.io/en/stable/operator-manual/signed-release-assets/)
