# 38 · Push deploys: a namespace-scoped ServiceAccount and Role

> Issue: #38 (4.1) · Phase 4

## What
A ServiceAccount **`github-deployer`** in namespace `push`, bound by a Role to exactly what
deploying the app needs there: apply the push overlay and watch the rollout. GitHub Actions
will use it in #39. To make that safe, the manifests are split by **who owns what**: the
namespace and its guardrails (Pod Security, quota, limits, network policy) moved out of the
overlay, into a part only an admin applies.

## Why
CI is the most exposed credential in the project: it runs on someone else's machines and is
triggered by pushes. If its identity can do everything, one leaked token or one malicious
workflow change owns the cluster. With a Role in one namespace, the worst case is "someone
redeploys or breaks the app in `push`". They can't touch `gitops`, `kube-system`, Secrets, or
the rules that contain them.

The split matters as much as the Role. Before, `kubectl apply -k k8s/overlays/push` also
applied the Namespace (with its Pod Security labels), the ResourceQuota, the LimitRange and
the NetworkPolicies. A deployer allowed to apply that could set Pod Security to
`privileged`, raise its own quota, or delete the default deny. Each of those is an
escalation path.

Alternatives considered:
- **Bind the built-in `edit` ClusterRole in the namespace**: a one-liner, but it includes
  Secrets, pods/exec, and most namespaced kinds, far more than a deploy needs.
- **An admin kubeconfig in CI**: one leaked secret is the whole cluster.
- **Keep one kustomization and give the Role rights on the guardrails**: CI could weaken them.
- **Only ArgoCD (pull) deploys**: that's the other half of this phase. The push path exists
  to compare the two.

## How it works
- **RBAC is additive and scoped.** A Role lists allowed (API group, resource, verb)
  combinations inside one namespace. A RoleBinding grants it to subjects. There are no deny
  rules: anything not listed is refused. Because both are namespaced, nothing here can
  grant access outside `push`.
- **What `kubectl apply` needs:** `get` (read the live object for the 3-way merge),
  `create` (first time) and `patch` (afterwards). `kubectl diff` and `rollout status` add
  `list`/`watch`. `update` (full replace) and `delete` are never needed: this overlay is
  applied without `--prune`.
- **The ServiceAccount is an identity, not a pod's.** `automountServiceAccountToken: false`:
  no pod carries its token. #39 decides how CI proves it is this account.
- **Apply order** (for an admin, and later ArgoCD in #43): `k8s/namespaces/<name>` first
  (Namespace, guardrails, RBAC), then `k8s/overlays/<name>` (the app).

| Directory | Contents | Applied by |
|---|---|---|
| `k8s/base` | Deployment, Service, PDB, HPA | (included by overlays) |
| `k8s/overlays/push`, `k8s/overlays/gitops` | base + namespace, image digest, Ingress, Middleware | CI (#39) / ArgoCD (#42) |
| `k8s/namespace-base` (new) | LimitRange, ResourceQuota, NetworkPolicies | (included by namespaces) |
| `k8s/namespaces/push`, `k8s/namespaces/gitops` (new) | Namespace + Pod Security; push: ServiceAccount, Role, RoleBinding | admin |

## Implementation
- `k8s/namespaces/push/rbac.yaml`:
  - **deploy:** `get, list, watch, create, patch` on deployments, services,
    horizontalpodautoscalers, poddisruptionbudgets, ingresses, and Traefik middlewares.
  - **observe:** `get, list, watch` on replicasets, pods, pods/log, events.
  - **Not granted:** delete, update, Secrets, ConfigMaps, RBAC, NetworkPolicies,
    ResourceQuota, LimitRange, the Namespace, pods (create), pods/exec, port-forward.
- Files moved (`git mv`, content unchanged): `limitrange.yaml`, `resourcequota.yaml`,
  `networkpolicy.yaml` from `k8s/base` to `k8s/namespace-base`; each overlay's
  `namespace.yaml` to `k8s/namespaces/<name>`. New kustomizations carry the same labels as
  before, so live objects don't change.
- `scripts/render-k8s.sh` renders each overlay **with** its `k8s/namespaces/<name>` and
  runs every existing check on both. New checks:
  - **the split:** guardrail and identity kinds (Namespace, LimitRange, ResourceQuota,
    NetworkPolicy, ServiceAccount, Role, RoleBinding, Secret) never in an overlay, and
    nothing else in a namespace part;
  - **coverage:** where the `github-deployer` Role exists, it has `get`, `create` and
    `patch` for every kind in the overlay. A new kind in the overlay without a matching
    rule fails the render, not a deploy.

## Verification
**The refactor changes nothing live.** Normalized renders (sorted JSON) before and after:
identical for both namespaces, except the 3 new RBAC objects in `push`. On the cluster,
`kubectl diff` of the overlay showed nothing, and the namespace part showed only those 3
objects. After applying: `kubectl diff` clean for `namespaces/push`, `overlays/push` and
`namespaces/gitops`.

`gitops` didn't exist yet, so a "can't touch gitops" test would only say `NotFound`. It was
created from `k8s/namespaces/gitops` (namespace and guardrails, no app; ArgoCD needs it in
#40+), so the negative control returns a real `Forbidden`.

`kubectl auth can-i --as=system:serviceaccount:push:github-deployer`:

| Should be **yes** | | Should be **no** | |
|---|---|---|---|
| create/patch deployments `-n push` | yes | create deployments `-n gitops` | **no** |
| patch ingresses `-n push` | yes | get pods `-n gitops` | **no** |
| create middlewares `-n push` | yes | delete deployments `-n push` | **no** |
| patch HPAs `-n push` | yes | get secrets `-n push` | **no** |
| get pods/log `-n push` | yes | patch networkpolicies / resourcequotas `-n push` | **no** |
| watch replicasets `-n push` | yes | patch namespace `push` | **no** |
| | | create rolebindings, pods, pods/exec `-n push` | **no** |
| | | update deployments `-n push` | **no** |
| | | create deployments `-n kube-system`; list namespaces | **no** |

`can-i` only evaluates rules, so the real overlays were applied **as** the ServiceAccount
(`kubectl --as=…`):

| As `github-deployer` | Result |
|---|---|
| `apply -k k8s/overlays/push` (real) | all `unchanged` (the PDB `configured` is the usual annotation-only no-op, #33) |
| `diff -k k8s/overlays/push`; `rollout status` | exit 0; `successfully rolled out` |
| **Negative:** `apply -k k8s/overlays/gitops --dry-run=server` | `Forbidden: … cannot get resource "services" … in the namespace "gitops"` |
| **Negative:** `apply -k k8s/namespaces/push --dry-run=server` | `Forbidden: … cannot get resource "namespaces"` |
| **Negative:** `get secret lab-api-tls -n push` | `Forbidden` |

Render negatives: guardrails added to the push overlay, an HPA in `k8s/namespaces/push`, the
middlewares rule removed from the Role, `patch` removed from deployments, and
`k8s/namespaces/gitops` missing. Each fails `make k8s`, naming the objects.

## Gotchas
- **"Can create Deployments" means "can read the namespace's Secrets", indirectly.** A
  Deployment can mount any Secret in its namespace as a volume. A pod that prints it shows
  up in `pods/log`, and a pod labelled like the app could even serve it through the Ingress.
  So `push` must hold no Secret the deployer shouldn't have. Today that's only the TLS key,
  which the deployer's Ingress serves anyway. Pod Security `restricted` and default-deny
  egress narrow what such pods can do; they don't remove this.
- **The Namespace can't be in the deployer's kustomization**, even unchanged: `kubectl
  apply` would need `get` and `patch` on it, and patching a Namespace means changing its
  Pod Security labels.
- **Kustomize won't load files from outside a kustomization's directory**
  (`../../base/hpa.yaml` fails). Directories (`../../base`) are fine. A first attempt at a
  negative test failed for that reason instead of the intended one.
- **A Role can't give itself more.** RBAC prevents escalation: creating a RoleBinding
  needs the `bind` verb or already holding every permission it grants. Here RoleBindings
  aren't writable at all.
- **No credential exists yet.** The ServiceAccount has no token. #39 chooses between a
  long-lived token stored in GitHub and trusting GitHub's OIDC tokens in the API server
  (no stored secret).

## Further reading
- [Using RBAC authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [`kubectl auth can-i`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/)
- [Privilege escalation prevention in RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping)
