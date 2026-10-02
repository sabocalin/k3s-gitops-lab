# 90 · K3s pod network off the VPC range; pod DNS fixed

> Issue: #90 (1.13, a Phase 1 bug found in #28)

## What
K3s now uses **pods `10.52.0.0/16`**, **Services `10.53.0.0/16`** and cluster DNS `10.53.0.10`,
instead of its defaults. Those defaults overlapped the VPC `10.42.0.0/16`. Pods get their
upstream DNS from a K3s-specific file (`nameserver 169.254.169.253`, no search domains). An
Ansible guard fails the play if either range overlaps the VPC.

## Why
Since Phase 1, **pods could not resolve any external name**. K3s's default pod network
(`10.42.0.0/16`) was the same range as the VPC (#9). CoreDNS forwards to the VPC resolver
`10.42.0.2`, and from inside the cluster that address lies in the node's pod subnet
(`cni0` = `10.42.0.1/24`): queries went into the local pod bridge instead of to AWS.
- CoreDNS logged `read udp 10.42.0.8:…->10.42.0.2:53: i/o timeout`.
- `nslookup github.com.` from a pod: 5 s, then failure.
- In-cluster FQDNs without a trailing dot hung too: with `ndots:5`, the search list is tried
  first, and it included `taild18d72.ts.net`, inherited from the node's Tailscale DNS. That
  suffix was sent upstream and timed out.
- Image pulls kept working (containerd runs on the host), which hid the problem.

It would have broken cert-manager's ACME (#36), ArgoCD's git access, and Alloy.

Alternatives considered:
- **Only point pod DNS at `169.254.169.253`, keep the ranges** — no rebuild, but the overlap
  stays: pods still cannot reach VPC addresses, which bites with VPC endpoints or a second node.
- **Re-address the VPC instead** — replaces the platform network for the same result.
- **`tailscale up --accept-dns=false` on the node** — removes the search domain, but not the overlap.

## How it works
```
pod (10.52.0.x) ─▶ CoreDNS 10.53.0.10 ─┬─ *.cluster.local: answered in-cluster
                                       └─ everything else ─▶ 169.254.169.253 (Amazon DNS,
                                          link-local: same address in every VPC; reached
                                          through the node, flannel masquerades the source)
kubelet --resolv-conf=/etc/rancher/k3s/resolv.conf: pods inherit no host search domains
```
- **The guard** reads the VPC's ranges from the instance metadata service (IMDSv2:
  `…/network/interfaces/macs/<mac>/vpc-ipv4-cidr-blocks`) and compares them with Python's
  `ipaddress.overlaps`. It fails closed: if the metadata service cannot be read, the play stops.
- **The ranges cannot change on a live cluster:** K3s stores them at first start. The fix
  needed a fresh cluster (`make down`, remove the Tailscale device, `make up`, `make kubeconfig`).

## Implementation
`ansible/roles/k3s/defaults/main.yml` (`k3s_cluster_cidr`, `k3s_service_cidr`,
`k3s_cluster_dns`, `k3s_upstream_dns`), `templates/config.yaml.j2` (`cluster-cidr`,
`service-cidr`, `cluster-dns`, `resolv-conf`), `templates/resolv.conf.j2`, the guard task in
`tasks/main.yml`. The README's Architecture section lists the three ranges.

## Verification
| Check | Before (#28) | After |
|---|---|---|
| `169.254.169.253` from a pod, tested before changing anything | answered (`github.com` → `140.82.121.4`); `10.42.0.2` failed | chosen as the upstream |
| Node pod subnet / cluster DNS / API Service | `10.42.0.0/24` / `10.43.0.10` / `10.43.0.1` | `10.52.0.0/24` / `10.53.0.10` / `10.53.0.1` |
| Pod `resolv.conf` search | `… cluster.local taild18d72.ts.net eu-central-1.compute.internal` | `default.svc.cluster.local svc.cluster.local cluster.local` |
| `github.com`, `acme-v02.api.letsencrypt.org`, `ghcr.io` from a pod | 5 s, failed | resolved in 2–7 ms |
| `kubernetes.default.svc.cluster.local` (no trailing dot) | hung (>4 s) | `10.53.0.1` in about 2 ms |
| HTTPS out (`https://ghcr.io/v2/`) | — | 401 in 0.13 s (reachable; it wants credentials) |
| CoreDNS errors | constant `i/o timeout` | 0 since start |
| `lab-api.push.svc.cluster.local` from a pod | 000 (timeout) | 200, DNS 1.8 ms |
| #28 rollout test, repeated on the new network | 0/1181 failed | **0/850 failed** |
| Guard, real ranges (`--check`) | — | `no overlap with VPC 10.42.0.0/16` |
| **Negative: guard with K3s's defaults** (`-e k3s_cluster_cidr=10.42.0.0/16`) | — | `pods 10.42.0.0/16 overlaps VPC 10.42.0.0/16`, `failed=1` |
| **Negative: Service range inside the VPC** (`10.42.200.0/24`) | — | `services 10.42.200.0/24 overlaps VPC 10.42.0.0/16`, play stopped |

## Gotchas
- **A working image pull proves nothing about pod DNS.** containerd resolves on the host, so
  the cluster looked healthy for two phases.
- **Defaults collide.** K3s defaults to `10.42.0.0/16` for pods; picking the same /16 for the
  VPC looked harmless in #9. Any two ranges that may ever route to each other must be planned
  together; the guard now enforces it.
- **`ndots:5` turns short external names into search-list lookups first.** A slow search
  suffix delays every lookup; pods now inherit no host search domains.

## Further reading
- [K3s networking options (cluster-cidr, service-cidr, cluster-dns)](https://docs.k3s.io/cli/server#networking)
- [K3s: `resolv-conf`](https://docs.k3s.io/cli/agent#node)
- [Amazon DNS server addresses](https://docs.aws.amazon.com/vpc/latest/userguide/AmazonDNS-concepts.html#AmazonDNS)
- [Kubernetes DNS for Services and Pods (ndots, search)](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
