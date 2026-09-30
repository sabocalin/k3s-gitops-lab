# 15 · Local kubeconfig over Tailscale

> Issue: #15 (1.8) · Phase 1

## What
`kubectl --context k3s-gitops-lab` works from the laptop. The context lives in its own
file, `~/.kube/k3s-gitops-lab.yaml` (mode 600), points at
`https://k3s-node.taild18d72.ts.net:6443`, and reaches it through the userspace Tailscale
client's SOCKS5 proxy (`proxy-url: socks5://localhost:1055`). Port 6443 stays closed to the
internet.

## Why
kubectl is the everyday tool for Phases 3–5. The Kubernetes API is the most sensitive
endpoint in the project (the admin credential can do anything), so it is reachable only
inside the tailnet, from a device you own and have logged in.

Alternatives considered:
- **Open 6443 to your IP** — an internet-facing admin API, and home/office IPs change.
- **`ssh -L 6443:...` tunnel each time** — works, but manual and fragile.
- **Merge into `~/.kube/config`** — on this laptop, one file per cluster is the rule: a bad
  merge into the shared file can lose every other context.

## How it works
```
kubectl --context k3s-gitops-lab
   └─ proxy-url socks5://localhost:1055 ─▶ userspace tailscaled ─▶ WireGuard
        └─▶ k3s-node:6443 (TLS; certificate valid for k3s-node.taild18d72.ts.net, #14)
```
- **Why a SOCKS proxy:** in userspace mode Tailscale does not create a network interface or
  routes (that is what keeps it from touching the employer VPN). Programs reach the tailnet
  through its SOCKS5 proxy instead; kubectl supports that per cluster with `proxy-url`.
- **Why the name, not the IP:** the tailnet IP changed when the node was re-registered;
  the MagicDNS name did not. `tailscaled` resolves MagicDNS names itself for SOCKS
  connections, so the laptop's own DNS is not involved.
- **Credential:** K3s's admin kubeconfig uses a client certificate and key (cluster-admin).
  It was copied by the owner, never printed or seen by the assistant.

### Runbook: (re)create the kubeconfig
Needed after a rebuild (the cluster gets a new CA and admin certificate).
```sh
umask 077 && ssh k3s-node 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed -e 's#https://127.0.0.1:6443#https://k3s-node.taild18d72.ts.net:6443#' \
        -e 's/: default$/: k3s-gitops-lab/' \
  > ~/.kube/k3s-gitops-lab.yaml
F=~/.kube/k3s-gitops-lab.yaml
kubectl --kubeconfig $F config set \
  clusters.k3s-gitops-lab.proxy-url socks5://localhost:1055
kubectl --kubeconfig $F config unset current-context
```
Then `kcreload` (or a new terminal tab). Every edit uses `--kubeconfig <this file>`: with a
`KUBECONFIG` list, kubectl writes to the **first** file, which on this laptop is an employer
cluster.

## Implementation
Nothing in the repo besides this runbook: the kubeconfig is a local, private file.
Local: `~/.kube/k3s-gitops-lab.yaml` (600, no `current-context`), picked up by `kcreload`.

## Verification
| Check | Result |
|---|---|
| `get nodes` (Tailscale up) | `k3s-node Ready control-plane v1.36.4+k3s1` |
| Access level | `auth can-i '*' '*'` → yes (cluster-admin) |
| 404 control | `pods "no-such-pod" not found` (a real API answer, not 401/timeout) |
| **Tailscale down (negative control)** | `Unable to connect to the server: socks connect ... general SOCKS server failure` |
| Tailscale up again | `k3s-node Ready`; laptop prefs kept (ShieldsUp, hostname) |
| Public port 6443 | timed out (control portquiz.net:6443 succeeds) |
| File | 600, one context/cluster/user, `current-context` null (doctor: clean) |
| Active context after merge | unchanged: identical with and without this file in the same merge order |

## Gotchas
- **The fresh shell does not see the file** until `kcreload` runs in *your* shell: `KUBECONFIG`
  is exported once per session; a new tab or `kcreload` rebuilds it.
- **A file that sets `current-context` can silently switch clusters** when merged; this one
  sets none. Other pre-existing files in `~/.kube` do, which is why a differently ordered
  merge picked a different active context.
- **Shell aliases can collide with helper names** (`k` is an alias here); name throwaway
  functions distinctly.
- **The admin certificate is long-lived.** Rebuilding the node rotates it (new cluster, new
  CA). Treat the file like a password.

## Further reading
- [kubeconfig proxy-url](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/#proxy)
- [K3s cluster access](https://docs.k3s.io/cluster-access)
- [Tailscale userspace networking (SOCKS5)](https://tailscale.com/kb/1112/userspace-networking)
