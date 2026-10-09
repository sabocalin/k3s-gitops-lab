# 51 · K3s upgrade via system-upgrade-controller (v1.36.4 → v1.37.1)

> Issue: #51 (5.4) · Phase 5

## What
Rancher's **system-upgrade-controller** (SUC) runs in namespace `system-upgrade` and
upgrades K3s from a **Plan** object: "nodes matching this selector should run this
version". The Plan lives in git (`k8s/platform/upgrade-plans`), and Argo CD applies it.
The first Plan did a minor upgrade, **v1.36.4+k3s1 → v1.37.1+k3s1**, on the live node.

## Why
An upgrade used to mean SSH plus Ansible on the node, or re-running the installer. Both
are imperative and leave no record of which version should be running. With a Plan, an
upgrade is a reviewed one-line PR, applied by the same pull path as everything else (#43),
and the version in git is the version on the node.

Alternatives considered:
- **Ansible (`k3s_version` + re-run the role)**: already there for fresh nodes. But it
  is a push from the laptop, and it doesn't cordon, order or report like SUC.
- **K3s's automated upgrades with a `channel` instead of a `version`**: SUC can follow
  `stable` by itself. But "the node upgrades whenever upstream releases" is exactly the
  silent drift the project avoids; a pinned version changes only through a PR.
- **Rebuild on the new version (#52/#64)**: valid for a single disposable node, and it is
  what `k3s_version` does now. In-place keeps the cluster's state and takes seconds.

## How it works
```
PR: Plan k3s-server .spec.version = v1.37.1+k3s1 ─▶ merge ─▶ Argo CD applies the Plan
system-upgrade-controller: the node's K3s version differs from the Plan's
  ─▶ Job on that node (privileged, host filesystem mounted):
       init: kubectl cordon k3s-node        (no new pods land meanwhile)
       upgrade: rancher/k3s-upgrade@sha256:… copies the k3s binary over
                /usr/local/bin/k3s, restarts the k3s service
  ─▶ K3s restarts (API down ~14 s); containers keep running; kubelet re-registers v1.37.1
  ─▶ Job succeeds ─▶ uncordon
K3s then re-applies its bundled add-ons (Traefik, CoreDNS, …) at the versions 1.37.1 ships
```
- **Why running pods survive.** K3s doesn't stop containers when its service restarts;
  containerd keeps them running. kube-proxy's iptables rules and the ServiceLB (klipper)
  port forwards stay in place, so Traefik keeps routing while the API is gone.
- **Cordon, no drain.** On one node a drain would evict every pod with nowhere to go. The
  cordon only stops new pods from landing while the binary is swapped; SUC uncordons when
  the Job succeeds.
- **Pinned by digest.** The controller appends `:<version>` only to a bare image name
  (`WithLatestTag`, which only tags `reference.IsNameOnly` images), so
  `rancher/k3s-upgrade@sha256:…` is used as written.

## Implementation
- `k8s/platform/system-upgrade/`: the v0.20.2 release assets `system-upgrade-controller.yaml`
  and `crd.yaml`, unmodified (sha256s matched GitHub's asset digests, vendor/SHA256SUMS).
  - Namespace `system-upgrade` enforces "privileged", with the reason recorded (#54's
    rule): the upgrade Job mounts the host filesystem and runs privileged.
  - The controller image is pinned by digest. **Not cosign-signed on Docker Hub**
    (checked), so digest only.
  - The image the Jobs use to cordon is set in a ConfigMap. Upstream had
    `rancher/kubectl:v1.30.3` by tag (the image check, which reads containers, never sees
    it); now `rancher/kubectl@sha256:06c7a7a9…` (v1.36.2, within one minor of the
    cluster before and after). A `test` op catches upstream changing it.
  - Resources 24/96 Mi; `Prune=false` on the CRD and the Namespace.
- `k8s/platform/upgrade-plans/plan-k3s-server.yaml`: `version: v1.37.1+k3s1`,
  `concurrency: 1`, nodes with `node-role.kubernetes.io/control-plane=true`,
  `cordon: true`, `upgrade.image` by digest (`rancher/k3s-upgrade:v1.37.1-k3s1`, not
  cosign-signed, checked). v1.37.1 was the v1.37 channel's latest, 9 days old.
- Applications `system-upgrade` and `upgrade-plans` (the second retries until the CRD
  exists). The `platform` AppProject gains namespace `system-upgrade` and kind `Plan`.
- `ansible/roles/k3s/defaults/main.yml`: `k3s_version: v1.37.1+k3s1`, so a fresh node
  (`make up`, the weekly rebuild) installs the same. Both change in one PR from now on.

## Verification
Pre-merge, the two Applications ran from the branch in a temporary project (`test-51`),
so the upgrade below was the real one. A poller on the laptop requested the public
`https://k3s-gitops-lab.duckdns.org/health` every 0.5 s throughout.

| Time (UTC) | Event |
|---|---|
| 14:35:26 | Applications created (after a server dry run) |
| 14:36:01 | Plan resolved `v1.37.1-k3s1`; upgrade Job created |
| 14:36:07 | node cordoned |
| 14:36:18 – 14:36:32 | API unreachable (K3s restarting), about 14 s |
| 14:36:44 | node `v1.37.1+k3s1`, uncordoned, Job succeeded |
| 14:36:37 – 14:37:02 | K3s re-applies its add-ons: Traefik chart 40.1.4 → 41.4.2, new Traefik pod 14:37:00, old pod stopped 14:37:02; CoreDNS replaced |
| 14:37:05 | **one failed request** (connection failure) |

| Check | Result |
|---|---|
| **Done when:** minor upgrade completed | `kubectl version`: server `v1.37.1+k3s1`; node uncordoned |
| App availability, public HTTPS, every 0.5 s | **214 of 215 OK** from 14:35:30 to 14:38:00. During the binary swap and the K3s restart: 0 failures. 1 failure at the Traefik chart switch, 20 s after the upgrade |
| Pod restarts (before vs after) | lab-api pods in `push` and `gitops`: none. `argocd-application-controller-0`: +1. Replaced by K3s's add-on upgrade: Traefik, CoreDNS, the helm-install Jobs |
| Argo CD | all 10 Applications Synced/Healthy (`lab-api-gitops` showed Degraded during the restart and recovered at 14:37:04) |

Negative control, to find the cause of the one failure: `kubectl rollout restart
deploy/traefik` (a Traefik pod replacement, now new chart to new chart) under the same
poller gave **0 failures**. A pod swap alone doesn't drop requests. The failure belongs to
the one-time switch from the old chart's pod to the new one: the old pod was stopped
2 seconds after the new one started.

## Gotchas
- **A K3s minor upgrade also upgrades its bundled add-ons.** Traefik, CoreDNS,
  metrics-server and local-path come with K3s, at the versions it ships. Here Traefik went
  from chart 40 to 41 (Traefik 3.7). That change, not the K3s restart, cost the one failed
  request. Read the release notes' "Embedded component versions" before a minor upgrade.
- **"Available throughout" on one node is about Traefik, not the app.** The app's 6 pods
  never restarted; the single Traefik replica is the single path in. Two Traefik replicas
  (a `HelmChartConfig`) would cover add-on upgrades too; left as a follow-up.
- **The laptop's kubectl is 1.34**: `kubectl version` warns that 1.34 vs 1.37 exceeds the
  supported ±1 skew. CI pins kubectl 1.36.4 (`scripts/lib/tools.sh`), within one minor.
- **SUC's cordon image lives in a ConfigMap**, as an environment variable. Image checks that
  read pod specs miss it, and upstream pinned a 1.30 kubectl by tag.

## Further reading
- [K3s: automated upgrades with system-upgrade-controller](https://docs.k3s.io/upgrades/automated)
- [system-upgrade-controller: Plan spec](https://github.com/rancher/system-upgrade-controller/blob/master/doc/plan.md)
- [K3s v1.37 release notes](https://docs.k3s.io/release-notes/v1.37.X)
- [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/)
