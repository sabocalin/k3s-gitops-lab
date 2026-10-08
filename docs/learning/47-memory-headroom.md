# 47 · Memory headroom before adding ArgoCD and observability

> Issue: #47 (5.0) · Phase 5 (checked now, before Phase 4's ArgoCD)

## What
A measured memory baseline of the node (`t4g.small`, 2 GiB) with everything up to #39
running, a budget for what Phases 4–5 add, and a **decision with thresholds**: stay on
`t4g.small`, install ArgoCD (#40), measure, and move to `t4g.medium` only if the
measurements cross the gates below. The resize path is checked and ready.

## Why
On a 2 GiB node, running out of memory doesn't fail cleanly. The kernel swaps (slow), then
the OOM killer picks a victim, and on a single node that may be K3s itself. That takes the
API server and every controller down with it. Adding ArgoCD, External Secrets and Alloy
blind risks exactly that. The opposite mistake is paying for 4 GiB before it's needed.

Alternatives considered:
- **Move to `t4g.medium` now**: 4 GiB, safe, about $1.54/month at 40 h (not covered by the
  `t4g.small` free trial). Recommended in the session; deferred by decision until ArgoCD's
  real usage is known.
- **Trim to fit**: disabling the unused local-path provisioner and K3s's Helm controller
  frees maybe 50–100 Mi. Fewer app replicas would undo #28. Not enough on its own for
  about 500 Mi of additions.
- **No observability**: cuts Phase 5's point (#48, #49).

## How it works
- `free`'s **available** column (`MemAvailable`) is the number that matters: free memory
  plus page cache the kernel can drop. "used" includes cache and overstates the problem.
- `kubectl top` shows each container's **working set** (what cgroups count against limits),
  lower than process RSS. Pods are only part of the node: K3s itself, containerd and the
  system daemons live outside any pod.
- **PSI** (`/proc/pressure/memory`) says how much time tasks spent stalled waiting for
  memory. `some avg300` above about 1% means memory is slowing real work, even before any
  OOM kill.
- **Swap** (1 GiB, swappiness 10, #14) is a buffer for spikes, not working memory. Steady
  swap growth is the early warning.

## Baseline (2026-10-07, 22 min after boot, idle)
Everything through #39: K3s, Traefik, CoreDNS, metrics-server, local-path-provisioner,
cert-manager (3 pods), lab-api (3 pods), Tailscale, the DuckDNS unit.

| Measure | Value |
|---|---|
| `kubectl top node` | 103m CPU (5%), **1288Mi (70%)** |
| `free -m` | total 1835, used 1281, buff/cache 608, **available 553** |
| Swap | **108 Mi used** of 1023 (already, 22 min after boot) |
| PSI memory | `some avg300=0.00`, `full avg300=0.00` (no stalls now) |
| Requests / limits (scheduler view) | memory 460Mi (25%) / 906Mi (49%) of 1835Mi allocatable |

Biggest processes (RSS, MiB):

| Process | MiB |
|---|---|
| `k3s-server` (API server, controller manager, scheduler, kubelet, SQLite datastore, flannel, network policy) | **707** |
| containerd | 143 |
| traefik | 76 |
| lab-api (python3.13) × 3 | 50 each |
| metrics-server, cert-manager controller | 47 each |
| cainjector, tailscaled, local-path-provisioner, coredns | 33–41 each |
| snapd, cert-manager webhook | 25 each |

All pods together: **283 Mi** working set. The node's real consumer is the K3s process.

## Budget for what's next (estimates)
| Component | Estimate (MiB) |
|---|---|
| ArgoCD core (#40): application-controller, repo-server, redis, applicationset | 250–400 |
| External Secrets Operator (#54) | 60–100 |
| Alloy (#48) | 100–150 |
| **Total** | **≈ 450–650** vs **553 available** |

## Decision and gates
**Stay on `t4g.small`, install ArgoCD (#40), measure.** Measured the same way as above,
idle, at least 15 minutes after a fresh `make start`.

| Gate | Stay small if all of these hold | Otherwise |
|---|---|---|
| **A**, after ArgoCD (#40) | `MemAvailable` ≥ 300 Mi; swap used ≤ 300 Mi; PSI `some avg300` < 1; no OOM kills (`dmesg`, pod `OOMKilled`) | move to `t4g.medium` before continuing |
| **B**, before Alloy (#48) or External Secrets (#54) | `MemAvailable` ≥ that component's estimate + 200 Mi margin | move first, or trim (local-path provisioner, Helm controller) |

**The resize path, checked:** `terraform/instance` has `var.instance_type`, and CI's apply
role already allows only `t4g.small`/`t4g.medium` (#16). A read-only plan with
`-var instance_type=t4g.medium`: **`aws_instance.node will be updated in-place`**,
`0 to add, 1 to change, 0 to destroy`. Terraform stops the instance, changes the type and
starts it again; the disk, the cluster and its certificate stay. Cost:

| | `t4g.small` | `t4g.medium` |
|---|---|---|
| On-demand, eu-central-1 (AWS Price List API) | $0.0192/h | $0.0384/h |
| ~40 h/month | **$0 until 2026-12-31** (trial), then $0.77 | $1.54 |
| 24/7 | $14.01 | $28.03 |

## Outcome (#40)
**Gate A failed on `t4g.small`**: with Argo CD running, 297 Mi available, swap 762–853 Mi,
memory stall (PSI `some avg300`) about 30%. Argo CD was scaled to 0 and the node resized to
**`t4g.medium`** (in place, from a saved plan). There, Gate A passed: 2250 Mi available,
swap 0, PSI 0, no OOM kills; Argo CD's pods use 182 Mi. Details:
[40-argocd-core.md](40-argocd-core.md).

## Verification
- Measurements: `free -m`, `/proc/meminfo`, `/proc/pressure/memory`, `ps -eo rss,comm`
  on the node over Tailscale SSH; `kubectl top node`, `kubectl top pods -A`,
  `kubectl describe node` (allocated resources) from the laptop.
- Prices: `aws pricing get-products` for both types in `eu-central-1`, Linux, shared tenancy.
- Resize path: `terraform plan -var instance_type=t4g.medium` (read-only, not applied).

## Gotchas
- **"70% used" is not "30% left" in any useful sense.** `kubectl top node` reports the node's
  working set, which includes active page cache. `MemAvailable` estimates what can actually
  be handed out without swapping. Plan with that one.
- **The pods aren't the problem.** 283 Mi for every pod, 707 Mi for `k3s-server`.
  Optimizing app memory would barely move the total.
- **Swap in use 22 minutes after boot** means the working set already exceeds RAM a
  little at times (startup peaks). It's harmless at this level, and it's the first thing
  to watch after #40.
- **The free trial covers `t4g.small` only.** `t4g.medium` is billed from the first hour,
  so moving costs money now, not only after 2026-12-31.

## Further reading
- [`free(1)`: the available column](https://man7.org/linux/man-pages/man1/free.1.html)
- [PSI: pressure stall information](https://docs.kernel.org/accounting/psi.html)
- [`kubectl top` and the working set](https://kubernetes.io/docs/reference/instrumentation/node-metrics/)
- [EC2: change the instance type](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-resize.html)
