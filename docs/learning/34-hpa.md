# 34 · HorizontalPodAutoscaler on CPU (min 3, max 5)

> Issue: #34 (3.8) · Phase 3

## What
A **HorizontalPodAutoscaler** (HPA) runs `lab-api` with between 3 and 5 pods, aiming for an
average CPU use of 70% of each pod's CPU request. The Deployment no longer says how many
replicas it has; the HPA decides.

## Why
Three pods handle normal traffic with lots of room (3m CPU each at idle, 6% of the request).
A spike needs more pods, but 5 pods all the time would cost memory on a 2 GiB node for no
benefit. The HPA adds pods when CPU rises and removes them when it falls, within limits that
the node and the namespace quota can hold.

Alternatives considered:
- **Fixed 5 replicas**: simple, but it pays for the peak all day.
- **KEDA**: scales on queue length, events, cron, and down to zero. A whole operator for a
  CPU rule; worth it once something event-driven exists.
- **Vertical Pod Autoscaler**: makes pods bigger instead of adding more, and restarts them to
  do it. Doesn't help availability, and conflicts with an HPA on the same metric.
- **Scale on request rate** (custom metrics via Prometheus Adapter): closer to what users
  feel, but there is no Prometheus yet. Possible after #48.

## How it works
- **metrics-server** (built into K3s) asks each kubelet for container CPU every 15 s and
  serves it at `metrics.k8s.io`. That's what `kubectl top` shows too.
- The **HPA controller** (in kube-controller-manager) runs every 15 s:
  `desired = ceil(current replicas × current utilization / target)`, where utilization is
  usage ÷ **request** (50m, #30). With no CPU request there is nothing to divide by, and the
  HPA reports `<unknown>`. The LimitRange (#30) makes sure a request always exists.
- **Tolerance:** if `current / target` is within 0.9–1.1, nothing happens. So at a 70%
  target, scale-up starts above about 77% and scale-down below about 63%.
- **Scale-up** acts at once (default policy: up to +100% or +4 pods per 15 s). **Scale-down**
  uses a 300 s stabilization window: the HPA picks the *highest* recommendation of the last
  5 minutes, so a brief dip doesn't remove pods the next spike needs.
- The HPA writes `spec.replicas` through the Deployment's **scale subresource**. The
  Deployment then creates or removes pods as usual (rolling-update rules don't apply to
  scaling).

## Implementation
- `k8s/base/hpa.yaml`: `autoscaling/v2`, target `Deployment/lab-api`, `minReplicas: 3`,
  `maxReplicas: 5`, CPU `averageUtilization: 70`. `behavior` left at the defaults (above).
  - **min 3**: one pod gone for a drain or rollout still leaves 2, matching the PDB (#32).
  - **max 5**: 5 pods, plus the rollout's surge pod, is 6 × (50m/64Mi requests,
    250m/128Mi limits) = 300m/384Mi requests and 1.5/768Mi limits. That fits the
    ResourceQuota (400m/512Mi, 2/1Gi, 8 pods, #30) and the node's free memory.
- `k8s/base/deployment.yaml`: **`replicas: 3` removed.** With it in the manifest, every
  `kubectl apply` (and ArgoCD sync, #42) would reset the count the HPA chose.
- `scripts/render-k8s.sh`: exactly one HPA targeting the Deployment; the Deployment sets
  no `replicas`; `maxReplicas + maxSurge` fits the quota's pod count; the PDB's
  `minAvailable` must be below the HPA's `minReplicas`.

### Removing `replicas` from a live Deployment safely
`kubectl apply` (client-side) remembers what it last applied in the
`kubectl.kubernetes.io/last-applied-configuration` annotation. A field that was in the old
manifest and is missing from the new one gets **deleted**, and a Deployment without
`spec.replicas` defaults to **1**. `kubectl diff` showed exactly that: `replicas: 3` → `1`,
which would kill 2 of 3 pods before the HPA scaled back up. The PDB doesn't stop it, because
scaling down isn't an eviction. The documented migration: rewrite only the annotation, then
apply.
```sh
kustomize build k8s/overlays/push | yq 'select(.kind=="Deployment")' > deploy.yaml
kubectl apply set-last-applied -f deploy.yaml   # annotation only; spec.replicas stays 3
kubectl diff -k k8s/overlays/push               # now: only the new HPA
kubectl apply -k k8s/overlays/push
```
Replicas stayed at 3, all ready, through the apply. The `gitops` namespace has no
Deployment yet; ArgoCD (#40+) creates it fresh from this manifest, so no migration is needed.

## Verification
Load: a curl pod in a separate `loadtest` namespace, 20 parallel connections
(`curl -Z --parallel-max 20`) to Traefik's Service with the Host of a **temporary** Ingress
(removed afterwards; #35 adds the real one). That's client → Traefik → app, the only path
the #33 policies allow. About 670 requests per second for 240 s. Sampled every 15 s:

| t (s) | Load | HPA CPU | Desired | Spec | Ready | CPU per pod (m) |
|---|---|---|---|---|---|---|
| idle, before | off | 6% | 3 | 3 | 3 | 3 3 3 |
| 16 | on | 42% | 3 | 3 | 3 | 16 3 45 (metrics lag one 15 s window) |
| 32 | on | 344% | **5** | 5 | 3 | 198 195 124 |
| 47 | on | 484% | 5 | 5 | **5** | 247 247 233 (near the 250m limit) |
| 63–148 | on | 393–442% | 5 | 5 | 5 | about 190–210 each, over 5 pods |
| 175 | on | patch `replicas: 3` | | **3** | 3 | 2 pods killed |
| 183 | on | | 5 | **5** | 3→5 | HPA restored the count 8 s later |
| 240 | **off** | | | | | |
| about 573 | off | 6% | 3 | **3** | 3 | scale-down, 5 min 33 s after the load stopped |

- **Scale-up**: 3 → 5 in one step, 32 s after the load started (13:18:59Z). The formula
  asked for `ceil(3 × 344 / 70) = 15`, so `maxReplicas: 5` capped it. At 400%+ each pod
  sat near its 250m limit: the cap holds even when more pods "would help".
- **Requests**: **160,000, all 200**, including while 2 pods were killed by the patch and
  during scale-down (readiness and preStop from #28 drained them).
- **Scale-down**: `New size: 3; reason: All metrics below target` at 13:28:00Z, 5 min 33 s
  after the load ended. That's the 300 s stabilization window plus a couple of 15 s metric
  and sync periods. It then stayed at 3 (6%).
- **Negative: `minReplicas` holds the floor.** Idle at 6%, the formula gives
  `ceil(3 × 6 / 70) = 1`, but the HPA kept 3, before and after the test.
- **Negative: a `replicas:` in the manifest fights the HPA.** Patching `replicas: 3` (what
  applying the old manifest would do) killed 2 pods at once (`Killing` ×2, 13:21:22Z). The
  HPA set 5 again at 13:21:30Z. Two pods restarted for nothing, which is why `replicas:` is
  gone and the render check forbids it.
- **Negative: the replicas migration.** `kubectl diff` with the plain new manifest showed
  `replicas: 3 → 1`. After `set-last-applied` it showed only the new HPA.
- Render check, negative: `replicas: 3` back in the Deployment, no HPA, `maxReplicas: 8`
  (8 + 1 surge > quota of 8 pods), or `minReplicas: 2` (≤ PDB `minAvailable` 2) each fails
  `make k8s`.
- After cleanup (load namespace and test Ingress deleted): `kubectl diff -k` clean. The
  HPA-owned `replicas` is no longer in the manifest, so it never shows as drift.

The sampler stalled after t=208 (a `kubectl` call hung; several samples above also arrived
30–50 s late while the node's 2 vCPUs were saturated). The scale-down time comes from the HPA's
events instead.

## Gotchas
- **Removing `replicas:` from an applied manifest scales to 1** unless the last-applied
  annotation is fixed first (above). Server-side apply has the same issue with a different
  fix (field managers).
- **A manifest with `replicas:` fights the HPA.** Every apply resets the count; the HPA
  scales back on its next pass, and the pods in between are created and killed for nothing.
- **Utilization is relative to the request, not the limit.** A pod at 100% can still use up
  to its 250m limit, which is 500% "utilization". Changing requests changes when it scales.
- **Scale-down takes 5 minutes** by design (stabilization window). For a lab that seems
  slow; in production it prevents flapping.
- **A new Deployment starts at 1 replica** until the HPA's first pass (no `replicas:` in the
  manifest). Relevant when ArgoCD creates the `gitops` copy (#42).
- The PDB still says `minAvailable: 2`. At 5 replicas that allows 3 pods down at once.
  `maxUnavailable: 1` would hold at 1 for any replica count. Left as is (the issue specifies
  `minAvailable: 2`); worth changing later.
- The #33 default deny means load must come through Traefik, which is also the realistic
  path.

## Further reading
- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Migrating Deployments to horizontal autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#migrating-deployments-and-statefulsets-to-horizontal-autoscaling)
- [Configurable scaling behavior](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#configurable-scaling-behavior)
