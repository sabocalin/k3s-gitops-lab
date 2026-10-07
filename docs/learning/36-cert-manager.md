# 36 (part 2) · cert-manager + Let's Encrypt HTTP-01 (staging, then production)

> Issue: #36 (3.10), part 2 of 2 · Phase 3 · Part 1: [the fixed hostname](36-dynamic-dns.md)

## What
**https://k3s-gitops-lab.duckdns.org/** serves a trusted Let's Encrypt certificate, and plain
HTTP redirects to HTTPS. **cert-manager** (a set of controllers in the `cert-manager`
namespace) obtains the certificate, stores it as a Secret that Traefik serves, and renews it
before it expires. Two **ClusterIssuers** describe where certificates come from: Let's Encrypt
staging and production.

## Why
Without TLS every request and response crosses the internet readable and modifiable. A
certificate by hand (certbot on the node, copy into a Secret) expires every 90 days and
breaks the first time someone forgets. cert-manager makes issuance and renewal part of the
cluster's desired state: an annotation on the Ingress is the whole request.

Alternatives considered:
- **Traefik's built-in ACME resolver**: fewer moving parts, but certificates live in a file
  inside the Traefik pod (not Kubernetes Secrets) and its config is in K3s's Traefik
  HelmChartConfig, not in this repo's manifests.
- **DNS-01 challenge**: no port 80 needed, wildcards possible, but cert-manager has no
  in-tree DuckDNS solver (a third-party webhook), and the token would have to live in the
  cluster too.
- **AWS Certificate Manager**: free, but only usable on AWS load balancers (README "never
  create").
- **Helm chart (`helm install`, or K3s's HelmChart CRD)**: the usual install. Here the
  upstream static manifest is vendored and patched with Kustomize, the same tooling as the
  app. ArgoCD (#43) will apply it from git like everything else.

## How it works
```
Ingress lab-api (push) ── annotation cert-manager.io/cluster-issuer: letsencrypt-prod
   │  ingress-shim (in the cert-manager controller) creates
   ▼
Certificate lab-api-tls ─▶ CertificateRequest ─▶ ACME Order ─▶ Challenge (HTTP-01)
   │                                                               │
   │   cert-manager creates, in namespace push:                    │
   │     solver pod (acmesolver, port 8089) + Ingress for          │
   │     /.well-known/acme-challenge/<token> on the same host      │
   │   self-check: cert-manager GETs that URL itself first ◀──────┘
   │   then asks Let's Encrypt to validate:
   │     LE ─▶ DNS k3s-gitops-lab.duckdns.org ─▶ node :80 ─▶ Traefik ─▶ solver pod
   ▼
Secret lab-api-tls (tls.crt + tls.key) ─▶ Traefik serves it on :443 for that host
renewal: cert-manager re-runs this 30 days before expiry (certificates last 90 days)
```
- **Staging first.** Same protocol, untrusted root, much higher rate limits. A mistake that
  retries against production can lock the name out for hours (5 failed validations per
  hour per account and name).
- **The self-check** keeps a broken setup from burning Let's Encrypt attempts: cert-manager
  only asks Let's Encrypt to validate once it can fetch the token itself.
- **Authorizations are reused.** Once an ACME account has proven control of a name, the
  proof stays valid for about 30 days, and re-issuing within that time needs no challenge.
  That matters for testing (see Verification).
- **The redirect and the challenge:** the app's routers on `:80` carry the redirect
  middleware. cert-manager's solver Ingress has a longer rule (host + the full challenge
  path), so Traefik gives it priority and the token is served over plain HTTP. Let's Encrypt
  would follow a redirect anyway.
- **The solver pod lands in the app namespace**, so #33's default deny applies to it. An
  extra NetworkPolicy lets Traefik reach pods labelled `acme.cert-manager.io/http01-solver`
  on port 8089.

## Implementation
- `k8s/platform/cert-manager/` (cluster-wide; applied by hand for now, ArgoCD in #43):
  - `vendor/cert-manager-v1.21.2.yaml`: the upstream release manifest, **unmodified**
    (v1.21.2, published 2026-09-11, past the 7-day cooldown). Its sha256 matched GitHub's
    published asset digest (`e03b668e…`) and is recorded in `vendor/SHA256SUMS`.
  - `kustomization.yaml`, everything this project changes:
    - `images:` controller, webhook and cainjector **by digest**. Each digest's cosign
      signature was verified against cert-manager's published key (see Gotchas for the
      flags it needs).
    - a JSON patch pinning the **acmesolver** image by digest too. It's a controller
      *flag* (`--acme-http01-solver-image=`), not a container, so `images:` can't reach it.
      An `op: test` makes the patch fail loudly if an upgrade moves the flag.
    - the namespace enforces Pod Security **`restricted`** (#31). The upstream pods already
      comply; applying showed no warnings.
    - **resources** (upstream sets none), from idle use measured on the node: controller
      47Mi, cainjector 22Mi, webhook 21Mi → requests 64/32/32Mi, limits 160/96/96Mi, 10m CPU.
- `k8s/platform/cluster-issuers/`: `letsencrypt-staging` and `letsencrypt-prod`, HTTP-01
  through `ingressClassName: traefik`. **A separate kustomization, applied second**:
  ClusterIssuers are instances of cert-manager's CRDs, and its webhook validates them, so
  both must exist first. No `email:` (Let's Encrypt stopped sending expiry mail in 2025;
  cert-manager renews by itself).
- `k8s/overlays/push/ingress.yaml`: `host: k3s-gitops-lab.duckdns.org`, `spec.tls` with
  `secretName: lab-api-tls`, `cert-manager.io/cluster-issuer: letsencrypt-prod`, entry
  points `web,websecure`, middleware `push-redirect-https@kubernetescrd`. The path allowlist
  from #35 is unchanged. With a host set, the bare IP and `<ip>.sslip.io` now get 404.
- `k8s/overlays/push/middleware.yaml`: Traefik `Middleware` `redirect-https`
  (`redirectScheme: https`, permanent 301). Plain Ingress has no redirect field.
- `k8s/base/networkpolicy.yaml`: `allow-traefik-to-acme-solver` (above).
- `scripts/render-k8s.sh`:
  - every Ingress host is covered by `spec.tls`, with a known ClusterIssuer;
  - `k8s/platform/*` is rendered and checked: vendored hashes, images (and `--*-image=`
    flags) by digest, requests and limits, Pod Security `restricted`. It goes into a
    subdirectory so CI's job summary stays small.
  - `echo "$objects"` became `printf '%s\n'`: `echo` in `sh` (dash on CI) turns the `\n`
    inside CRD descriptions into real control characters, and jq then rejects the JSON.
- `.github/scripts/ai_review.py`: `vendor/` paths excluded from the AI review diff (1 MB of
  upstream YAML would fill its 100k-character budget).

## Verification
| Check | Result |
|---|---|
| cert-manager install | 3 Deployments ready under `restricted`, no Pod Security warnings |
| ClusterIssuers | both `ACMEAccountRegistered` |
| **Staging certificate** | `Ready` about 30 s after the apply; served cert `CN=k3s-gitops-lab.duckdns.org`, issuer `(STAGING) Dastardly Durum YR1`; laptop curl rejects it (exit 60, untrusted, as it should) |
| **Negative: solver NetworkPolicy removed** (a fresh name `negtest.k3s-gitops-lab.duckdns.org`; see below) | challenge stuck: `Waiting for HTTP-01 challenge propagation: wrong status code '502', expected '200'`, nothing sent to Let's Encrypt |
| Policy restored from git | same challenge done, `negtest` Ready in about 25 s; removed afterwards |
| **Production certificate** | `Ready` about 30 s after switching the annotation; issuer `Let's Encrypt YR2`, valid to 2027-01-05 |
| From the laptop, system trust store | `Verify return code: 0 (ok)`, TLS 1.3; `https://…/health` → **200** without `-k` |
| Redirect | `http://…/health` → **301** `https://…/health` |
| Path allowlist over HTTPS | `/metrics`, `/docs`, `/ready` → 404 |
| Bare IP | `http://<ip>/health` → 404 (no Host match) |
| Render negatives | vendored file changed, solver-image patch or a digest removed, resources removed, namespace `baseline`, TLS block removed, unknown issuer, host outside `spec.tls` → `make k8s` fails, naming the problem |
| **Stop/start** (new IP `52.59.236.109`) | same certificate (serial `06BF6568…` before and after), no new CertificateRequest; `https://…/health` → 200 through the new IP once Traefik was up |

**Why a different name for the negative control:** the first attempt deleted the policy and
the certificate's Secret on the main name. cert-manager re-issued *without a challenge*,
because the staging account's authorization for that name was still valid. A sub-name nobody
had validated (DuckDNS resolves any `*.k3s-gitops-lab.duckdns.org`) forced a real HTTP-01
challenge.

## Gotchas
- **cert-manager's image signatures need two non-default cosign flags.** Their key is an RSA
  KMS key signing **SHA-512** digests: without `--signature-digest-algorithm sha512`, cosign
  reports `crypto/rsa: verification error`. The signatures also aren't found in the Rekor
  transparency log by cosign 3's lookup, so the check needs `--insecure-ignore-tlog=true`.
  That still verifies the signature against the key, and the signed payload names the
  exact digest, but it skips the "was this logged" part. Negative: the controller's digest
  checked under the webhook's name → `no signatures found`.
- **CRDs and their objects can't be applied together** the first time (`no matches for
  kind`, or the webhook not ready yet). Hence two kustomizations. In ArgoCD (#43) this
  becomes sync waves.
- **A dry run can't see into a namespace it would create.** `--dry-run=server` on a fresh
  install fails for every object in `cert-manager` (`namespaces "cert-manager" not found`);
  the real apply is fine.
- **The solver pod obeys the app namespace's policies**: default deny (#33), Pod Security
  `restricted` (it complies), LimitRange and ResourceQuota (#30). At the HPA's maximum of 5
  pods plus a surge pod, a solver pod is the 7th of 8 allowed.
- **Authorizations are cached for about 30 days**, so "delete the Secret and watch it
  re-validate" doesn't test the challenge path.
- **`kubectl apply` reports the webhook configurations as `configured`** every time:
  cert-manager's cainjector writes a CA bundle into them. ArgoCD will need
  `ignoreDifferences` for `caBundle` (#43).
- **The certificate names the DuckDNS host and is public** in Certificate Transparency logs
  (crt.sh), like every publicly trusted certificate.
- Memory: the node went from 54% to 66% used with cert-manager. That's input for #47.

## Further reading
- [cert-manager: ACME HTTP-01](https://cert-manager.io/docs/configuration/acme/http01/)
- [cert-manager: securing Ingress resources (ingress-shim)](https://cert-manager.io/docs/usage/ingress/)
- [cert-manager: install with kubectl (static manifest)](https://cert-manager.io/docs/installation/kubectl/)
- [Let's Encrypt: staging environment](https://letsencrypt.org/docs/staging-environment/) and [rate limits](https://letsencrypt.org/docs/rate-limits/)
- [Traefik: RedirectScheme middleware](https://doc.traefik.io/traefik/middlewares/http/redirectscheme/)
