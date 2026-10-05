# 30 · Requests, limits, LimitRange and ResourceQuota

> Issue: #30 (3.4) · Phase 3

## What
The app container declares **requests** (50m CPU, 64Mi) and **limits** (250m, 128Mi). Every
namespace gets a **LimitRange** (defaults for containers that declare nothing, and a
per-container maximum) and a **ResourceQuota** (a total budget; pods that would exceed it are
rejected). The render check (`k8s-render`) now requires every container to declare all four values.

## Why
The node has 2 GiB and K3s uses about 1 GiB of it. Without memory limits, one leaking pod can
push the node into OOM and take K3s down with it. Without quotas, one namespace (or a runaway
autoscaler, #34) can starve the other. HPA (#34) measures CPU as a percentage of the
*request*, so requests must be realistic.

Alternatives considered:
- **No CPU limit, requests only** — common on big nodes; on this 2-vCPU burstable node, one
  runaway pod would starve the control plane.
- **Guaranteed QoS (requests = limits)** — reserves 4–5× the measured CPU per pod for nothing.

## How it works
| Object | Values | Effect |
|---|---|---|
| app `resources` | requests 50m / 64Mi, limits 250m / 128Mi | scheduler reserves the request; over 128Mi → OOM-killed, over 250m → throttled |
| LimitRange `container-defaults` | default requests 50m/64Mi, default limits 250m/128Mi, max 500m/256Mi | fills in missing values at admission; refuses containers above max |
| ResourceQuota `namespace-budget` | pods 8, requests 400m / 512Mi, limits 2 / 1Gi | refuses a pod that would exceed the namespace total |

Measured before choosing (`kubectl top`): idle **3m / 37Mi** per pod; under sustained load
(4 parallel curl loops, 158 req/s over 3 pods) up to **75m**, memory **flat at 37Mi**. The quota
fits the HPA maximum (5) plus one surge = 6 app pods, plus 2 helper pods at the defaults.
Both objects live in the base, so each namespace gets its own copy.

## Verification
| Check | Result |
|---|---|
| Quota after the rollout | `used: requests.cpu=150m, requests.memory=192Mi, limits.cpu=750m, limits.memory=384Mi` |
| **(a) pod without resources** (Done-when) | got `requests 50m/64Mi, limits 250m/128Mi`; annotation `LimitRanger plugin set: cpu, memory request … limit …` |
| **(b) pod over quota** (Done-when) | first 200Mi pod created; second: `Forbidden: exceeded quota: namespace-budget, requested: requests.memory=200Mi, used: requests.memory=456Mi, limited: requests.memory=512Mi` |
| (c) container above max | `Forbidden: maximum memory usage per Container is 256Mi, but limit is 300Mi` |
| (d) memory limit enforced | 50 MiB allocated fine; 200 MiB → exit 137, kernel `Memory cgroup out of memory: Killed process … (python3.13) … UID:65532`, container `OOMKilled`, restarted (other pods kept serving) |
| **Negative: render check** | resources removed from the Deployment → `containers without cpu/memory requests and limits: lab-api` (both overlays) |
| Restored | `kubectl diff -k` clean |

## Gotchas
- **"Rollout finished" does not mean the old pods are gone.** The first memory test hit a pod
  of the *old* ReplicaSet, still in its 5 s preStop and without limits, so a 200 MiB allocation
  "succeeded". Select pods by the newest ReplicaSet, excluding terminating ones.
- **An OOM kill takes the whole container.** The cgroup OOM killer killed the exec'd process
  *and* the app's PID 1: they share one memory budget. A leak anywhere in the container
  restarts the app.
- **Quota counts terminating pods** until they are gone (`pods=4` right after a 3-replica rollout).
- **The load client was the bottleneck** (1.4 CPU for curl processes, the app under 0.1 CPU).

## Further reading
- [Resource management for pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [LimitRange](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [ResourceQuota](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
