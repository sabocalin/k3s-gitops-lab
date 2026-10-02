# 27 · Kustomize base and overlays: push and gitops namespaces

> Issue: #27 (3.1) · Phase 3

## What
The layout for every Kubernetes manifest. `k8s/base/` holds what the app *is* (a
Deployment and a Service). `k8s/overlays/push/` and `k8s/overlays/gitops/` say *where* it
runs: their own namespace, a `deploy-path` label, and the image pinned by digest.
`kubectl kustomize k8s/overlays/<name>` renders each one into its own namespace.

## Why
Phase 4 runs the same app through two delivery paths side by side: GitHub Actions pushes the
`push` overlay with `kubectl apply -k` (#39), and ArgoCD pulls the `gitops` overlay from git
(#40–42). One base keeps them identical except for what must differ.

Alternatives considered:
- **Helm** — templates plus a values layer; more than one app with two variants needs. Helm
  stays for third-party charts (cert-manager, #36).
- **A copy of the YAML per namespace** — the copies drift.
- **jsonnet / cdk8s** — a programming language for configuration; too much here.

Kustomize is built into kubectl (`apply -k`) and supported natively by ArgoCD. It patches
plain YAML instead of templating it, so the base stays valid Kubernetes YAML you can read.

## How it works
```
k8s/base/kustomization.yaml     resources: deployment.yaml, service.yaml
                                labels: app.kubernetes.io/name   (also in selectors)
                                        app.kubernetes.io/part-of (metadata + pods)
k8s/overlays/<p>/kustomization.yaml
                                resources: namespace.yaml, ../../base
                                namespace: <p>          → every object lands in <p>
                                labels: k3s-gitops-lab/deploy-path: <p> (metadata + pods)
                                images: lab-api → digest sha256:e57c89b4… (signed, #25)
```
- **Selectors are immutable** once a Deployment exists, so only one stable label goes into them
  (`includeSelectors: true` for `app.kubernetes.io/name` only). Every other label is
  `includeSelectors: false`: changing it later never means deleting and recreating the
  Deployment.
- **`includeTemplates: true`** puts the metadata labels on the **pods** too; Kustomize does not
  do that by default for non-selector labels. NetworkPolicy (#33) and metrics select pods by
  label.
- **The base names no build.** `image: ghcr.io/sabocalin/k3s-gitops-lab/lab-api` without a tag,
  and each overlay's `images:` sets the digest. CI will bump the gitops digest (#41).
- **`targetPort: http`** refers to the container port by name, so the Service survives a port
  change.

### The render check (`scripts/render-k8s.sh`, `make k8s`, CI job `k8s-render`)
It renders each overlay with a **hash-pinned kustomize 5.8.1** (not kubectl's built-in, which is
5.7.1 on this laptop and differs per machine) and fails unless:
- there is exactly one Namespace, named after the overlay;
- every other object is in that namespace (so nothing else is cluster-scoped);
- every container image is pinned by digest;
- every pod template carries `k3s-gitops-lab/deploy-path: <overlay>`;
- no namespace is shared between overlays.

## Implementation
`k8s/base/{kustomization,deployment,service}.yaml`,
`k8s/overlays/{push,gitops}/{kustomization,namespace}.yaml`, `scripts/render-k8s.sh`,
`scripts/lib/tools.sh` (kustomize: 5.8.2 was under 7 days old, so 5.8.1; hashes match the
release's `checksums.txt` and my download; no upstream attestation), `.github/workflows/k8s.yml`,
`make k8s`. The ruleset now requires `zizmor, terraform-lint, ruff, pytest, k8s-render`.

## Verification
| Check | Result |
|---|---|
| `kubectl kustomize k8s/overlays/push` (Done-when) | Namespace `push`; Service and Deployment with `namespace: push`; image `…/lab-api@sha256:e57c89b4…` |
| `kubectl kustomize k8s/overlays/gitops` | the same in `gitops`; pods labelled `deploy-path=gitops` and `part-of`; selector only `app.kubernetes.io/name` |
| `make k8s` / CI run 37011773757 | `ok: gitops`, `ok: push` (3 objects each), `all overlays OK (kustomize 5.8.1)` |
| **Negative: overlay without `namespace:`** | `objects outside namespace 'gitops': Service/lab-api (namespace: none)` |
| **Negative: gitops reusing namespace `push`** | `expected exactly one Namespace named 'gitops', got 'push'` |
| **Negative: no image digest** | `images not pinned by digest: ghcr.io/sabocalin/k3s-gitops-lab/lab-api` |
| **Negative: a ClusterRole in the base** | `objects outside namespace …: ClusterRole/oops` (both overlays) |
| **Negative: missing file in the base** | `kustomize build failed` |
| **CI negative** (commit `0a5020b`, run 37011847222) | `k8s-render` failed: `objects outside namespace 'gitops'`; revert (run 37011893823) passed |

Not yet checked: the rendered objects against the cluster's real API (`--dry-run=server`). That
happens when the app is first applied, with the node running (#28 onward).

## Gotchas
- **In zsh, `path` is `PATH`.** A loop `for path in push gitops` replaced the command search path
  for that shell: every command after it was "not found", and the overlay files were never
  written. Use another variable name.
- **Non-selector labels skip pod templates by default.** The first render had `part-of` and
  `deploy-path` on the Deployment but not on its pods; `includeTemplates: true` fixes it.
- **kubectl's built-in kustomize lags** (5.7.1 here, 5.8.1 pinned). For identical output
  everywhere, render with the pinned binary.

## Further reading
- [Kustomize: labels (includeSelectors, includeTemplates)](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/)
- [Kustomize: images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/)
- [Kubernetes: immutable Deployment selectors](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#label-selector-updates)
- [ArgoCD and Kustomize](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/)
