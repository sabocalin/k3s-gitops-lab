# 32 · PodDisruptionBudget minAvailable 2

> Issue: #32 (3.6) · Phase 3

## What
A **PodDisruptionBudget** (PDB) in each namespace says "keep at least 2 ready `lab-api` pods
during voluntary disruptions". `kubectl drain`, node upgrades and cluster-autoscaler
scale-downs remove pods through the **Eviction API**, and the API server refuses (HTTP 429) any
eviction that would break the budget.

## Why
#28 made *rollouts* safe: the Deployment never takes a pod down before its replacement is
ready. A *drain* is different. It removes pods from outside the Deployment, and without a
budget it evicts all 3 at once. The node upgrade in #51 (system-upgrade-controller) drains
the node, so that would mean a full outage on every upgrade.

Alternatives considered:
- **`maxUnavailable: 1`**: same effect at 3 replicas, and it scales better. Once the HPA
  (#34) runs 5 replicas, `minAvailable: 2` lets 3 go at once while `maxUnavailable: 1` still
  allows only 1. Kept the issue's `minAvailable: 2` for now; worth revisiting in #34.
- **A percentage (`66%`)**: rounds up, so it's harder to reason about at 3 pods. The render
  check now requires a plain number.
- **No PDB, rely on replicas**: replicas don't help. A drain evicts every pod on the node.
- **`minAvailable: 3` ("never lose a pod")**: allows **zero** evictions, so every drain hangs
  forever, even on a multi-node cluster with room elsewhere. The render check rejects it.

## How it works
- The **disruption controller** keeps the PDB's status up to date. `currentHealthy` counts
  ready pods matching the selector, and `desiredHealthy` is `minAvailable`.
  `disruptionsAllowed` is `currentHealthy - desiredHealthy`: 1 with 3 ready pods.
- `kubectl drain` first **cordons** the node (no new pods scheduled), then sends an
  `Eviction` for each pod. An eviction that would push `disruptionsAllowed` below 0 gets
  **429 TooManyRequests**; drain retries every 5 s until it succeeds or `--timeout` expires.
- Only *voluntary* removals go through the Eviction API. A plain `kubectl delete pod`, a node
  crash, an OOM kill or a Deployment rollout ignore the budget. Rollouts are covered by
  `maxUnavailable: 0` (#28), and crashes are what replicas are for.
- **Single node:** the evicted pod's replacement cannot schedule on the cordoned node, so
  it stays `Pending`. `currentHealthy` stays at 2 and the next eviction is refused for good.
  On this cluster a full drain therefore **always blocks** while the PDB exists. That shows
  the budget works, but it also means #51 must not rely on a plain drain (see Gotchas).

## Implementation
- `k8s/base/pdb.yaml` (in the base, so both namespaces get it), `policy/v1`:
  - `minAvailable: 2`: of 3 replicas, 1 may be down at a time.
  - `selector: app.kubernetes.io/name: lab-api`: the same label as the Deployment's selector.
    Kustomize's `includeSelectors` label (#27) is added to PDB selectors too.
  - **`unhealthyPodEvictionPolicy: AlwaysAllow`** (non-default; the default is
    `IfHealthyBudget`). With the default, a pod that is running but **not ready** can only be
    evicted while the budget is met. So when 2 of 3 pods are broken, the broken pods pin
    themselves and block every drain. `AlwaysAllow` lets unready pods go, because evicting
    them costs no availability. The Kubernetes docs recommend it for most apps.
- `k8s/base/kustomization.yaml`: adds `pdb.yaml`.
- `scripts/render-k8s.sh`: requires exactly one PDB per overlay, with a selector equal to the
  Deployment's `matchLabels` and a numeric `minAvailable` below `replicas`.

## Verification
On the cluster (namespace `push`, 3 replicas), with an in-cluster curl loop against the
Service (`k8s/tests/request-loop.sh`, about 20 requests per second). The drain was limited
to the app's pods so CoreDNS and Traefik stayed up:
`kubectl drain k3s-node --pod-selector=app.kubernetes.io/name=lab-api --timeout=40s`

| Test | Result |
|---|---|
| **Drain with the PDB** | 1 pod `evicted`; the other 2: `Cannot evict pod as it would violate the pod's disruption budget`, retried every 5 s until the 40 s timeout, drain **exit 1**. Replacement pod `Pending` (node cordoned), PDB `ALLOWED DISRUPTIONS 0`. Requests: **561/561 OK** |
| **Negative: drain without the PDB** | all 3 `evicted` in 7 s, `node/k3s-node drained` (exit 0), 3 pods `Pending`, **0 ready endpoints**. Requests: 76 OK, **48 failed** (000), and the outage lasts until uncordon |
| **`AlwaysAllow`**: 2 pods made unready (SIGUSR1 drain toggle, #29), PDB `1/2 healthy, allowed 0` | evict an **unready** pod → `201 Success`; evict the **ready** pod → **429** |
| **Negative: `IfHealthyBudget`** (the default), same setup | evict the **unready** pod → **429** too: the broken pod pins itself |
| Render check, negative | no PDB / `minAvailable: 3` / `"66%"` / a wrong selector → `make k8s` fails, naming the problem |
| Restored | uncordoned, PDB re-applied, `kubectl diff -k` clean |

Eviction called directly (what drain does per pod):
```sh
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"<pod>","namespace":"push"}}' |
  kubectl create --raw /api/v1/namespaces/push/pods/<pod>/eviction -f -
```

## Gotchas
- **On one node, a full drain never finishes** while the PDB exists: the replacement pod
  has nowhere to go. For the K3s upgrade (#51), either let the upgrade plan cordon without
  draining (K3s restarts in place and the containers keep running), or knowingly drain
  with `--disable-eviction`, which deletes pods and bypasses the budget. Raising the drain
  timeout doesn't help: the drain still never finishes.
- **The budget doesn't cover `kubectl delete pod`**, rollouts or crashes. It isn't an
  availability guarantee, only a limit on voluntary evictions.
- **Kustomize also adds selector labels to the PDB.** A PDB written with `app: other` ended
  up selecting `app: other` AND `app.kubernetes.io/name: lab-api`: nothing. The render check
  compares the final selectors.
- `minAvailable` counts **ready** pods. A pod failing readiness (draining, starting) already
  uses up the budget, which is why `AlwaysAllow` matters.
- The drain test leaves the node **cordoned** when it times out; always `kubectl uncordon`.

## Further reading
- [Specifying a Disruption Budget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Unhealthy pod eviction policy](https://kubernetes.io/docs/tasks/run-application/configure-pdb/#unhealthy-pod-eviction-policy)
- [API-initiated eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)
