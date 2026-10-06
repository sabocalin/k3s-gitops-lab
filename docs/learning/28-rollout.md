# 28 · Deployment: 3 replicas, zero-downtime rolling updates

> Issue: #28 (3.2) · Phase 3

## What
The Deployment runs **3 replicas** and rolls out with `RollingUpdate`, `maxUnavailable: 0` and
`maxSurge: 1`. A **readiness probe** on `/ready` gates traffic, and a **`preStop` sleep** of
5 s delays shutdown. This was the app's first deploy to the real cluster (`push` namespace),
and a rollout under a curl loop had **0 failed requests out of 1181**.

## Why
A rollout replaces every pod. Zero failed requests needs three things together:

| Piece | What it prevents |
|---|---|
| `maxUnavailable: 0`, `maxSurge: 1` | dropping below 3 serving pods: an old pod goes only after a new one is **ready** |
| readiness probe (`/ready`) | traffic to a pod that is not listening yet or still warming up. Without a probe, "ready" means "the process started" |
| `preStop` sleep 5 s | traffic to a pod already shutting down: "remove from endpoints" and "SIGTERM" happen at the same moment, and routers learn of the first a little later |

Alternatives considered:
- **`Recreate` strategy** — all old pods stop before new ones start: guaranteed downtime.
- **`maxUnavailable: 25%` (the default)** — with 3 replicas Kubernetes rounds it down to 0
  anyway, but writing 0 states the intent.
- **`maxSurge: 3`** (start all new pods at once) — faster, but 6 pods at once on a 2 GiB node.
- **A shell `sleep` in preStop** — distroless has no shell; Kubernetes' built-in
  `lifecycle.preStop.sleep` (stable since 1.32) needs no binary in the image.

## How it works
```
rollout: start 1 new pod (4 total) ─▶ readinessProbe GET /ready every 2 s
           503 while warming up (not in the Service) ─▶ 200 → added to endpoints
         ─▶ pick 1 old pod: removed from endpoints AND preStop sleep 5 s starts
           (it keeps serving any request still routed to it)
         ─▶ SIGTERM → uvicorn lifespan shutdown (/ready 503) → exit 0
         ─▶ repeat until 3 new pods
```
Other settings: `revisionHistoryLimit: 5` (old ReplicaSets kept for `rollout undo`),
`progressDeadlineSeconds: 120` (a stuck rollout fails in 2 minutes, not 10),
`terminationGracePeriodSeconds: 30` (the preStop sleep counts towards it),
readiness `periodSeconds: 2, failureThreshold: 1`.

### First deploy to the cluster
- `kubectl apply -k k8s/overlays/push`, from the laptop for now. Phase 4 automates it (#39).
- **Server-side dry run first:** it validated the Deployment against the real API (1.36),
  including the `sleep` action. It cannot validate objects in a namespace that does not exist
  yet (`namespaces "push" not found`), so the Namespace was created first.
- The node pulled the signed image **anonymously, by digest**: 28.6 MB in about 7 s. All
  3 pods were ready 15 s after the apply.

## Verification
The client is a curl pod (`curlimages/curl:8.21.0` by digest) **in the cluster, calling the
Service**. `kubectl port-forward` would pin to one pod, which a rollout kills. About 20
requests per second, 2 s timeout, no retries; `k8s/tests/request-loop.sh`.

| Rollout (each under the loop) | Requests | Failed |
|---|---|---|
| **This configuration** (`rollout restart`, 15 s) | 1181 | **0**; 6 different pods answered (3 old, 3 new) |
| **Negative: naive**: no readiness probe, no preStop, `maxUnavailable: 1` | 925 | **24** (2.6%, connection failures) |
| Ablation: readiness kept, preStop removed | 789 | 0 |
| Ablation: preStop kept, readiness removed | 740 | **23** |

After each experiment the Deployment was re-applied from git; `kubectl diff -k` showed no
differences.

**What this shows:** the readiness probe is what prevents failures in this setup. The
preStop sleep made **no measurable difference here**. The client goes through kube-proxy on a
single node, where endpoint removal takes effect almost at once, so the race it guards against
did not occur. It is kept (it costs 5 s per pod shutdown) and will be measured again through
Traefik's Ingress in #35, where a separate router learns of endpoint changes later.

**Measured in #35:** through Traefik it matters. Rollouts without preStop failed about 1% of
requests (409 of 39,400: 502s and timeouts); with preStop, 0 of 51,600. See
[35-ingress.md](35-ingress.md).

## Gotchas
- **Pods cannot resolve external names** (found here, not caused by this task). The VPC
  (`10.42.0.0/16`, #9) overlaps K3s's default pod network (`10.42.0.0/16`). CoreDNS forwards to
  the VPC resolver `10.42.0.2`, which from inside the cluster is an address in the node's pod
  subnet (`cni0` is `10.42.0.1/24`). Every upstream query times out: CoreDNS logs
  `read udp 10.42.0.8:…->10.42.0.2:53: i/o timeout`, and `nslookup github.com.` from a pod
  takes 5 s and fails. Image pulls still work because containerd runs on the host. Cluster names
  work when looked up short (`lab-api`) or absolute (`…cluster.local.`). Without the trailing
  dot, the FQDN has fewer than `ndots:5` dots, so the search list is tried first, including
  `taild18d72.ts.net` (inherited from the node's Tailscale DNS); that query goes upstream and
  hangs. Fixed in #90 ([note](90-cluster-network-ranges.md)); the rollout test repeated on the new network: 0/850 failed.
- **A trial run during boot is not evidence.** The first 5-second trial failed while Traefik
  and its load-balancer pod were still starting. The second trial failed too, and that one was
  the DNS bug above. Diagnose before reading results.
- **zsh does not word-split `$VAR`**: `K="kubectl --kubeconfig …"; $K get nodes` runs a
  command literally named "kubectl --kubeconfig …". A function works; `kl` was taken by an
  alias, hence `lab_kubectl`.

## Further reading
- [Deployment rolling update strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment)
- [Container lifecycle hooks: sleep action](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/#hook-handler-implementations)
- [Pod termination flow](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [K3s: cluster-cidr and service-cidr](https://docs.k3s.io/cli/server#networking)
