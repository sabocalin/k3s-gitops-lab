# 35 · Service + Ingress on K3s's built-in Traefik

> Issue: #35 (3.9) · Phase 3

## What
An **Ingress** publishes the app on the node's public IP, port 80:
`http://<public-ip>.sslip.io/` and `/health`. K3s's bundled **Traefik** is the ingress
controller that implements it. The Service (`lab-api`, ClusterIP, from #27) was already in
place.

## Why
Until now the app was reachable only from inside the cluster (and, since #33, only from
Traefik). The Ingress is the one public door: one controller handles routing, and later TLS
(#36), for every app behind it. Each app doesn't need its own port or load balancer.

Alternatives considered:
- **Traefik's `IngressRoute` CRD**: regex hosts, middlewares, TCP routes. More capable, but
  it ties the manifests to Traefik. Plain Ingress works with any controller.
- **Gateway API** (`HTTPRoute`): the successor to Ingress. K3s's Traefik doesn't enable it
  by default; it can replace Ingress later.
- **A `LoadBalancer` or `NodePort` Service per app**: one port per app, no host or path
  routing, no shared TLS.
- **An AWS load balancer**: about $16+/month, on the README's "never create" list.

## How it works
```
laptop ─▶ 18.198.48.149:80 (EC2 public IP, security group allows 80 from anywhere)
      ─▶ svclb-traefik (K3s ServiceLB: a pod per node with hostPort 80 → Traefik's Service)
      ─▶ Traefik pod, entry point "web" (:8000 inside the pod)
      ─▶ router from the Ingress: Path(`/`) || Path(`/health`), any Host
      ─▶ a READY lab-api pod IP:8000 (from the EndpointSlices; Traefik load-balances
         itself and skips the Service's ClusterIP)
```
- Traefik's `kubernetesingress` provider watches Ingresses, Services and EndpointSlices, and
  rebuilds its routing table on every change. A pod that turns unready or starts terminating
  drops out of the EndpointSlice and then out of Traefik's server list.
- The NetworkPolicy from #33 lets exactly this hop through: Traefik's pods (kube-system) to
  the app's port 8000.
- A request matching no router gets Traefik's own `404 page not found` (`text/plain`). The
  app's 404 is JSON. That makes it easy to see who answered.

## Implementation
`k8s/overlays/push/ingress.yaml`:
- `ingressClassName: traefik`: explicit, though it's K3s's default class.
- **No `host:`**: the public IP, and so `<ip>.sslip.io`, changes on every `make start` (#61).
  A host in git would be stale after the next start. Any Host header (or the bare IP) matches.
- **Allowlisted `Exact` paths `/` and `/health`.** `Prefix: /` would also publish `/metrics`
  (internal numbers, scraped in-cluster in #48), `/ready`, and FastAPI's built-in `/docs` and
  `/openapi.json`.
- `traefik.ingress.kubernetes.io/router.entrypoints: web`: HTTP (:80) only. Without it,
  Traefik also serves the route on :443 with its self-signed default certificate. #36 adds
  HTTPS and the redirect.
- **Push overlay only.** Two host-less Ingresses (push and gitops) would claim the same
  requests. The gitops copy gets its own address with ArgoCD (#42/#44).

`scripts/render-k8s.sh`: every Ingress uses class `traefik`, points at a Service in the same
overlay, and uses only `Exact /` or `Exact /health`.

## Verification
From the laptop over the internet (no proxy; Tailscale on the laptop is userspace and carries
only SOCKS traffic, so this is the public path, outside the tailnet):

| Request | Result |
|---|---|
| `http://18-198-48-149.sslip.io/health` | **200** `{"status":"ok"}` |
| `http://18-198-48-149.sslip.io/` | **200** |
| `/metrics`, `/ready`, `/docs`, `/openapi.json`, `/healthz` | **404** (Traefik's `text/plain`: never reached the app) |
| `http://18.198.48.149/health` (bare IP, no sslip.io) | 200: no host rule |
| `https://…/health` (:443) | 404: not on the `websecure` entry point until #36 |
| **Negative: Ingress deleted** | `/health` **404**; re-applied → 200 |

Render check, negative: `Prefix /`, `Exact /metrics`, class `nginx`, or a backend Service
missing from the overlay each fails `make k8s`.

### preStop, measured through Traefik
#28 found the 5 s `preStop` sleep made no measurable difference for clients going through
kube-proxy, and left the question open for Traefik. Measured here: a curl pod in a separate
`loadtest` namespace sent 4 parallel connections to Traefik's Service (any Host, so this
Ingress) for 55 s around each `kubectl rollout restart`. The load was about 490 requests per
second, enough for the HPA (#34) to hold 5 pods during **both** variants.

| Rollout (5 pods) | Requests | Failed |
|---|---|---|
| with preStop, run 1 | 26,800 | **0** |
| with preStop, run 2 | 24,800 | **0** |
| preStop removed (`kubectl patch`), run 1 | 19,600 | **166**: 150 × `502`, 16 × timeout (3 s) |
| preStop removed, run 2 | 19,800 | **243**: 225 × `502`, 18 × timeout |

Restored from git afterwards (`kubectl apply -k`, `diff` clean, preStop back).

**Why:** deleting a pod starts two things at once. The kubelet sends SIGTERM (after preStop),
and the endpoints controller marks the pod terminating in the EndpointSlice. Traefik learns
of the second only after its watch delivers the change and it rebuilds its config. In that
gap it still sends requests to a pod whose server has already stopped accepting: `502 Bad
Gateway` (connection refused) or a timeout. With preStop the container keeps serving for 5 s
after it's marked terminating, which is longer than Traefik needs to drop it. kube-proxy
(#28) rewrites the node's iptables directly, so its gap was too small to hit. Traefik has no
retry by default (a `retry` middleware would hide some of these, for idempotent requests
only). The fewer total requests without preStop come from the failures themselves: each
timeout holds a connection for 3 s.

## Gotchas
- **The address changes on every start.** The Ingress copes (no host), but anything that
  needs a name, like a TLS certificate (#36), has to follow the new IP each time.
- **`Prefix: /` is the usual example and publishes everything**, including `/metrics` and the
  API docs. Allowlist paths instead.
- **Only one host-less Ingress per controller.** A second one in another namespace competes
  for the same requests.
- **Who answered a 404?** Traefik's is plain text, the app's is JSON.
- `kubectl apply` reports the PDB as `configured` on every run, with no spec change
  (generation unchanged). It's only kubectl's last-applied annotation (#33).

## Further reading
- [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [K3s: Traefik ingress controller](https://docs.k3s.io/networking/networking-services#traefik-ingress-controller)
- [K3s: ServiceLB](https://docs.k3s.io/networking/networking-services#service-load-balancer)
- [Traefik: Kubernetes Ingress provider](https://doc.traefik.io/traefik/providers/kubernetes-ingress/)
- [Traefik: Ingress annotations](https://doc.traefik.io/traefik/routing/providers/kubernetes-ingress/)
