# 39 · Push deploys: GitHub Actions joins the tailnet and runs kubectl apply

> Issue: #39 (4.2) · Phase 4

## What
`.github/workflows/deploy-push.yml` deploys `k8s/overlays/push` on every merge to `main`
that changes it. The job joins the tailnet as an **ephemeral** device tagged `tag:ci`,
logs in to the Kubernetes API as the `github-deployer` identity from #38, applies the
rendered manifests, and checks the result. It stores **no secrets**: GitHub's per-job OIDC
token is its only credential, for Tailscale and Kubernetes alike.

## Why
This is the "push" half of Phase 4: CI pushes changes into the cluster, as opposed to ArgoCD
pulling them (#40+). The API port is not on the internet (#10), so CI has to reach it the
way the laptop does, through the tailnet. And CI is the most exposed place a credential can
live, so the design goal was to keep nothing long-lived there at all.

Alternatives considered:
- **A ServiceAccount token as a GitHub secret**: simplest. But it's long-lived (or needs
  rotating), works from anywhere it leaks to, and is one more secret to manage.
- **A Tailscale auth key or OAuth client secret as a GitHub secret**: the usual
  `tailscale/github-action` setup; again a stored secret. Workload identity federation
  replaces it.
- **Open 6443 to GitHub's IP ranges**: thousands of shared ranges, and the API would face
  the internet.
- **A self-hosted runner on the node**: no network problem, but the runner would hold
  cluster credentials on the node itself, and every workflow could reach it.

## How it works
```
merge to main ─▶ deploy-push (environment: production → main only)
  1. render-k8s.sh: pinned kustomize + every invariant check          (same as k8s.yml)
  2. verify-image.sh: the digest in the overlay is signed by image.yml (#25)
  3. tailscale/github-action: GitHub OIDC token ─▶ Tailscale (trust credential for
     sub = repo:…:environment:production) ─▶ auth key for tag:ci, ephemeral
     ─▶ device joins; `tailscale ping k3s-node`
  4. nc: k3s-node:6443 open; :22 and :10250 NOT reachable (tailnet policy)
  5. deploy-push.sh: kubectl (pinned 1.36.4) with an exec credential plugin
       ci-github-token.sh ─▶ fresh GitHub OIDC token, audience k3s-gitops-lab
       ─▶ API server: issuer + audience + repository_id + sub checked
       ─▶ user "github:repo:sabocalin@238511101/k3s-gitops-lab@1385841640:environment:production"
       ─▶ RoleBinding github-deployer (push only)
     whoami = that user; can-i yes/no matrix; token for another audience refused
     kubectl apply -f rendered/push.yaml; rollout status; pods on the digest; public /health
job ends ─▶ tailscaled logs out ─▶ the ephemeral device is removed from the tailnet
```
- **One subject, three gates.** The OIDC `sub` claim
  `repo:sabocalin@238511101/k3s-gitops-lab@1385841640:environment:production` is checked by
  Tailscale (to issue a key), the API server (to accept the token), and AWS (for the
  existing apply role, #16). It's GitHub's immutable format: owner and repository by ID, so
  a renamed or re-created repository can't inherit any of it. Only jobs in the `production`
  environment, which GitHub allows on `main` only, get that subject.
- **Audience** separates uses of the same identity: the Kubernetes token asks for
  `k3s-gitops-lab`, Tailscale's for `api.tailscale.com/<client id>`, AWS's for
  `sts.amazonaws.com`. Each verifier refuses the others.
- **Tokens live minutes.** kubectl calls the exec plugin whenever it needs a credential, so
  a long rollout never runs on an expired token, and nothing is written to disk.
- **The tailnet policy** (Tailscale admin) moved from the default allow-all to:
  `autogroup:member → * (all ports)` (you and your own devices) and
  `tag:ci → tag:k3s tcp:6443`. Its built-in `tests` refuse to save any edit that lets
  `tag:ci` reach 22 or 10250, or that cuts your own access to 22 and 6443.
- **Fail closed when the node is off.** If the node is stopped, `tailscale ping` fails and
  the job is red. Re-run it after `make start`.

## Implementation
- **K3s API server** (`ansible/roles/k3s`): `kube-apiserver-arg:
  authentication-config=/etc/rancher/k3s/authentication-config.yaml`, with an
  `AuthenticationConfiguration` (`apiserver.config.k8s.io/v1`): JWT issuer
  `https://token.actions.githubusercontent.com`, audience `k3s-gitops-lab`, CEL claim rules
  for `repository_id` and the exact `sub`, username `"github:" + claims.sub`, and
  **`anonymous.enabled: false`** (see Gotchas). Values in `defaults/main.yml`. Applied with
  Ansible (`--check --diff` first; only the two files changed, then a K3s restart).
- **RBAC** (`k8s/namespaces/push/rbac.yaml`): the RoleBinding gains a second subject, the
  `User` above. The ServiceAccount stays (useful for `kubectl --as` tests).
- `scripts/ci-github-token.sh`: the exec credential plugin. It builds the ExecCredential
  JSON with `jq --arg`, so the token never passes through a format string.
- `scripts/deploy-push.sh`: kubeconfig in a temp file (server, the committed CA, the
  plugin); identity and least-privilege assertions; `kubectl apply -f` of exactly what
  render-k8s.sh produced (not kubectl's bundled kustomize); `rollout status`; every running,
  non-terminating pod on the rendered digest; `https://k3s-gitops-lab.duckdns.org/health`
  200; a job summary.
- `k8s/ci/cluster-ca.crt`: the cluster CA certificate (public; no private key). Only
  certificates signed by it are trusted; system CAs are not. **Changes on `make down`/`make
  up`** (new cluster): copy the new one in from the kubeconfig.
- `scripts/lib/tools.sh`: kubectl 1.36.4 pinned (3 platforms, dl.k8s.io's hashes);
  `fetch_tool` downloads to a flat file name, because kubectl's asset name is a path.
- `.github/workflows/deploy-push.yml`: `permissions: {}` at the top; the job has
  `contents: read` and `id-token: write`; `environment: production`; concurrency without
  cancelling; `tailscale/github-action` pinned by commit (v4.2.0), Tailscale 1.94.2 pinned
  by sha256, `use-cache: false`. zizmor: no findings.
- **GitHub** (environment `production`): variables `TS_OIDC_CLIENT_ID`, `TS_OIDC_AUDIENCE`
  (identifiers, not secrets). **Tailscale**: `tag:ci` in `tagOwners`; the grants and tests
  above; a trust credential for the subject above, scope Auth Keys write, tag `tag:ci`.

## Verification
Before the merge (the deploy job itself only runs on `main`):

| Check | Result |
|---|---|
| Ansible `--check --diff`, then apply | only `config.yaml` and the new auth config; K3s restarted; API `ok`; public `/health` 200 |
| **Found: anonymous access opened** | with the config file, K3s stops passing `--anonymous-auth=false`. From the laptop without credentials: `/version` and `/readyz` **200**, `/api` 403 as `system:anonymous` |
| After `anonymous.enabled: false` | `/version`, `/readyz`, `/api`, deployments: all **401** (K3s's original behaviour); admin client certificate still `system:admin` |
| Committed CA | `curl --cacert k8s/ci/cluster-ca.crt` to the API: TLS verify 0; with system CAs only: exit 60 |
| kubectl pin | download matches the pinned hash; a wrong pinned hash → `SHA-256 mismatch … refusing to run it` |
| Tailnet policy saved | its tests passed (tag:ci: 6443 accept, 22 and 10250 deny; you: 22 and 6443 accept); from the laptop, API and SSH still work |
| Render, zizmor | `make k8s` OK; `zizmor 1.30.1`: no findings |

After the merge: the first `deploy-push` run (one run, three attempts):

| Attempt | What happened |
|---|---|
| 1, node **stopped** | render, checks, image signature: ok. **Tailscale login through GitHub OIDC worked** (no stored secret), then `Ping host k3s-node did not respond` → job failed before any deploy step (fails closed). Post step logged the device out |
| 2, after `make start` | tailnet: `6443 succeeded`, `22` and `10250` **not reachable**. Kubernetes: `logged in as github:repo:sabocalin@238511101/k3s-gitops-lab@1385841640:environment:production`, then `no (want yes) can-i create deployments.apps -n push` → stopped before applying. Cause: the RoleBinding's new `User` subject was in git but `k8s/namespaces/push` (admin-applied) had not been applied. An unplanned negative control: **authenticated but not authorized is refused** |
| 3, after applying `k8s/namespaces/push` | all 6 `can-i` as expected; `token for another audience: refused`; apply (all unchanged); `successfully rolled out`; `all 5 running pods on sha256:7952a156…`; `https://k3s-gitops-lab.duckdns.org/health -> 200` |

From the laptop during attempt 3: `github-runnervm8df0l` (`tag:ci`) appeared on the tailnet;
**about 20 s after the job ended, no `tag:ci` device remained** (ephemeral).

The follow-up PR that recorded this also bumped the push overlay to a newly published,
signed digest (`sha256:1b612533…`), so its merge exercises a real rolling update through
CI.

## Gotchas
- **An authentication config file silently re-enables anonymous requests on K3s.** K3s
  logs `Not setting kube-apiserver 'anonymous-auth' flag due to user-provided
  'authentication-config' file` and moves on. Kubernetes' own default is anonymous *on*, so
  unauthenticated requests became `system:anonymous`. RBAC still blocked real resources,
  but `/version` and the health endpoints opened up. Fixed in the config itself
  (`anonymous: enabled: false`), and measured both ways.
- **The `gh variable set` prompt needs a terminal.** Run through Claude Code's `!` it got no
  input and failed with `missing required key: value`; `--body` works.
- **Admin-owned changes don't deploy themselves.** The RoleBinding change lived in
  `k8s/namespaces/push`, which CI deliberately cannot apply (#38). Until an admin applies it,
  the job authenticates and is then refused. Apply `k8s/namespaces/*` before merging
  anything that depends on it. ArgoCD takes this over in #43.
- **The cluster CA is pinned in git.** After a rebuild the deploy fails with an x509 error
  until `k8s/ci/cluster-ca.crt` is updated. That's on purpose: it fails closed.
- **`tailscale/github-action` caches binaries by default.** For a deploy job that's turned
  off; the tarball is pinned by sha256 instead.
- **One OIDC user, one environment.** A job without `environment: production` gets a
  different `sub` (`…:ref:refs/heads/main`, `…:pull_request`). Tailscale refuses to issue
  a key, and the API server refuses the token (`token is not from the production
  environment`).

## Further reading
- [Kubernetes: structured authentication configuration](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration)
- [kubectl exec credential plugins](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins)
- [GitHub: OpenID Connect in Actions](https://docs.github.com/en/actions/concepts/security/openid-connect)
- [Tailscale: workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation)
- [Tailscale: ephemeral nodes](https://tailscale.com/kb/1111/ephemeral-nodes) and [policy tests](https://tailscale.com/kb/1337/policy-syntax#tests)
