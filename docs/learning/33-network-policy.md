# 33 · NetworkPolicy: default deny, allow Traefik to the app

> Issue: #33 (3.7) · Phase 3

## What
Two NetworkPolicies in each namespace. `default-deny` blocks **all ingress and all egress** for
every pod. `allow-traefik-to-lab-api` then lets exactly one thing back in: Traefik's pods (the
ingress controller in `kube-system`) to the app's port `http` (8000). K3s enforces them with its
built-in network policy controller (kube-router), so nothing was installed.

## Why
Before this, any pod in any namespace could call the app directly, bypassing whatever the
ingress will enforce (TLS in #36, and later rate limits or auth). In the other direction, a
compromised app pod could reach the API server and the **EC2 instance metadata service**
(IMDS), which serves the node role's credentials. The baseline below shows both were open. The
app makes no outbound calls at all, so blocking egress costs nothing.

Alternatives considered:
- **Ingress-only default deny**: the common first step, but it leaves egress open, including IMDS.
- **Cilium or Calico**: L7 and DNS-name egress rules, but they replace flannel and need
  hundreds of MiB on a 2 GiB node. Plain L3/L4 rules are enough here.
- **Disable K3s's controller (`--disable-network-policy`)**: then policies are accepted by the
  API server and silently do nothing.
- **Block IMDS at the node only (hop limit 1)**: already in place for IMDSv2 tokens (#10),
  but a TCP connection still opened (baseline). The policy blocks it per pod as a second layer.

## How it works
- A pod with **no** policy selecting it accepts everything. Once any policy selects it for a
  direction (`policyTypes`), only traffic some policy allows gets through, in that direction.
  Policies only ever add allowed traffic: `default-deny` selects every pod and allows nothing,
  and `allow-traefik-…` adds one hole. There's no ordering and no "deny" rule.
- A connection needs both ends to agree: **egress** allowed at the client's pod and **ingress**
  allowed at the server's pod. Traefik lives in `kube-system`, which has no policies, so its
  egress is open. The app's ingress lets it in.
- **kube-router** (inside the K3s process) watches pods and policies and writes iptables
  rules: a chain per pod (`KUBE-POD-FW-…`) jumping to a chain per policy (`KUBE-NWPLCY-…`). It
  marks allowed packets, logs denied ones (NFLOG, 10/min), and **rejects** them, so a blocked
  connection fails immediately (curl exit 7, Python `ConnectionRefusedError`), not after a
  timeout.
- **Kubelet probes still work.** Every pod chain starts with "permit traffic to pods when
  source is the pod's local node" (`-m addrtype --src-type LOCAL -j ACCEPT`). Probes come from
  the kubelet on the node, so they are never blocked. This is kube-router behaviour; other
  CNIs differ.
- Policies match **after** the Service has been translated to a pod address, so the port in
  the rule is the pod's (8000, named `http`), not the Service's 80.

## Implementation
- `k8s/base/networkpolicy.yaml` (base, so both namespaces):
  - `default-deny`: `podSelector: {}` (every pod, including future ones), `policyTypes:
    [Ingress, Egress]`, no rules.
  - `allow-traefik-to-lab-api`: selects `app.kubernetes.io/name: lab-api`; one `from` peer with
    **both** `namespaceSelector` (`kubernetes.io/metadata.name: kube-system`) and
    `podSelector` (`app.kubernetes.io/name: traefik`). Both selectors in the same list item
    means AND. Two items would mean OR: every pod in kube-system, plus any pod labelled
    traefik in the app's own namespace. `kubernetes.io/metadata.name` is set by the API server,
    so a namespace can't claim to be kube-system.
- **Selectors written explicitly** (`deployment.yaml`, `service.yaml`; `pdb.yaml` already
  did), and `includeSelectors: false` in `k8s/base/kustomization.yaml`. With
  `includeSelectors: true` Kustomize also writes the label into NetworkPolicy *peer*
  selectors. It **overwrote** `app.kubernetes.io/name: traefik` with `lab-api` (same key),
  turning the rule into "lab-api pods in kube-system": nothing, so Traefik was blocked. The
  rendered Deployment and Service are byte-identical before and after (`diff` of both overlays),
  which matters because Deployment selectors are immutable.
- `scripts/render-k8s.sh`: each overlay needs a default deny (`podSelector {}`, Ingress and
  Egress, no rules) and a policy on the app's pods with one peer that is exactly kube-system
  AND traefik.

## Verification
Same matrix before and after `kubectl apply -k k8s/overlays/push`. The in-cluster clients
are curl pods calling the Service's ClusterIP, and the public path goes through a temporary
Traefik Ingress for `18-198-48-149.sslip.io` (removed afterwards; #35 adds the real one).

| Path | Before | After |
|---|---|---|
| laptop → internet → Traefik → app | 200 | **200** (30/30, all 3 pods answered) |
| pod in `default` → app | 200 | **000** (curl exit 7, rejected at once) |
| pod in `default` **labelled `app.kubernetes.io/name: traefik`** → app | 200 | **000**: the AND with the namespace holds |
| pod in `push` (same namespace, not Traefik) → app | 200 | **000** |
| app pod → API server `10.53.0.1:443` | connected | **ConnectionRefusedError** |
| app pod → IMDS `169.254.169.254:80` | connected | **ConnectionRefusedError** |
| app pods ready, probe failures | 3/3 | 3/3, **no** `Unhealthy` events after the apply |

The "Before" column is the negative control: the same probes succeed without the policies,
so the 000s come from the policies and not from a broken test.

Render check, negative: dropping the policies, turning `includeSelectors` back on, splitting the
peer into two items (OR), or removing `Egress` from the default deny each fails `make k8s`.

## Gotchas
- **Kustomize label transformers reach into NetworkPolicy peer selectors.** `includeSelectors`
  silently overwrote a selector pointing at *another* app. Write selectors yourself once
  NetworkPolicies are involved.
- **AND vs OR is one dash.** `- namespaceSelector: … podSelector: …` (one item, AND) versus a
  second `- podSelector:` (two items, OR). The OR version still "works" in a happy-path test.
- **The identity is a label.** Anyone who can create a pod labelled
  `app.kubernetes.io/name: traefik` in kube-system gets through. That namespace is admin-only
  here.
- **Default deny egress breaks in-namespace test clients.** The #28 request loop (a curl pod
  in `push` calling the Service) no longer works, and neither does DNS from such a pod. Later
  load tests (#34) go through the Ingress or need their own allow policy.
- **Future scrapers need a hole.** Metrics collection (#48) must get an ingress rule to
  `/metrics`, and anything the app later calls needs egress (and DNS to CoreDNS on 53/UDP+TCP).
- A cosmetic one: after these edits `kubectl apply` reported the PDB as `configured` though
  `kubectl diff` showed nothing and its `generation` stayed 3. Only kubectl's last-applied
  annotation was rewritten.

## Further reading
- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [K3s: network policy controller](https://docs.k3s.io/networking/networking-services#network-policy-controller)
- [kube-router network policy](https://www.kube-router.io/docs/user-guide/#network-policy)
- [Kustomize `labels` field](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/)
