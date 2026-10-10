# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# k3s-gitops-lab — working rules for Claude

This is a learning project. For EVERY task, teaching is part of the deliverable.
This overrides terse/short-answer preferences inside this repo only.

## Per task

1. **Before implementing:** explain what the component is, why the project needs it,
   and the alternatives considered (one line each, with why not).
2. **While implementing:** explain how it works — the mechanism, not just the config.
   Call out every non-default setting and why it was chosen.
3. **After implementing:** show how it was verified, including a negative control
   (prove the thing fails when it should, not only that it passes).
4. **Write it down** in `docs/learning/<issue-number>-<slug>.md` using the sections in
   [`docs/learning/_template.md`](docs/learning/_template.md), add a row to
   [`docs/learning/README.md`](docs/learning/README.md), and link the note from the PR description.

## Conventions

- One branch per issue: `gh issue develop <n> --checkout`. PR body contains `Closes #<n>`.
- Signed commits, squash merge only; `main` is protected by a ruleset (no direct push).
- Near-$0 budget on a paid AWS account with no credits: check the README cost model and
  "Never create" list before adding any AWS resource. Always `AWS_PROFILE=personal`; the
  `default` profile on this laptop is an employer production account.
- Pin everything: actions by commit SHA, images by digest, tools by exact version.
- Personal GitHub account only. Use `GH_TOKEN=$(gh auth token --user sabocalin) gh ...`
  so the global gh account is never switched.
- Never reuse anything from this repo's free-tier AI setup on employer code.

## Commands

Every check CI runs has a local twin. None of these need AWS or the node.

```sh
make test        # app: ruff check, ruff format --check, pytest (uv, --frozen)
make k8s         # render every Kustomize tree and check the invariants (scripts/render-k8s.sh)
make lint        # terraform fmt/validate, tflint, trivy; strips all AWS credentials first
make image       # build lab-api:dev for linux/arm64
make run         # app on localhost:8000 with reload
```

Single tests:

```sh
cd app && uv run --frozen pytest tests/test_app.py::<test_name>
python3 -m unittest discover -s .github/scripts -v   # the AI-review script's tests
```

Node lifecycle (needs `aws login --profile personal`; kubectl also needs Tailscale up):
`make start | stop | extend | status | plan | up | down | kubeconfig`, all in
`scripts/lab.sh`, which refuses any AWS account but the lab's. `make kubeconfig` writes a
credential: the user runs it, not Claude. Use `kubectl --context k3s-gitops-lab ...`, never
`kubectl config use-context`.

Tools (kustomize, kubectl, tflint, trivy, cosign) are downloaded at exact versions and
SHA-256 checked by `scripts/lib/tools.sh`; bump a version there with every platform's hash.

## Architecture

One t4g.medium EC2 node running K3s, built entirely from this repository. The README has
the diagram, the cost model and the OIDC role table; `docs/architecture/` has full diagrams.

- **Terraform, four stacks** with separate S3 state: `bootstrap` (state bucket, budget,
  GitHub OIDC roles; laptop-only, so CI can't widen its own permissions), `platform`
  (VPC, security groups, IAM for node/ESO/autostop), `instance` (the node; stopped when
  idle, destroyed and rebuilt weekly), `grafana` (alerting; run through
  `scripts/tf-grafana.sh`, which gets the token from SSM so it never lands in state).
  SSM parameters are created by hand; Terraform only knows their names.
- **The node configures itself.** `terraform/instance/user_data.sh.tftpl` restores the
  node identity from SSM (`/k3s-gitops-lab/node-identity/*`: K3s CAs, SA keys, Tailscale
  state, SSH host keys), so a rebuilt node keeps the same CA, tailnet IP and host key.
  Then it clones `main` and runs `scripts/node-bootstrap.sh`: Ansible locally
  (`ansible/site.yml`: swap, K3s at the pinned `k3s_version`, DuckDNS), then the Argo CD
  bootstrap. `.github/workflows/rebuild.yml` does destroy → apply → deploy → HTTPS check
  → stop every Sunday, so anything fixed by hand on the node is lost within a week.
- **Two delivery paths for the same app** (`app/`, FastAPI, distroless image on GHCR,
  signed):
  - *push*: `deploy-push.yml` runs `kubectl apply` of `k8s/overlays/push` over Tailscale,
    authenticating to the API server with GitHub OIDC (`k8s/ci/cluster-ca.crt` is the
    trusted CA). It triggers on changes to `k8s/base/**`, `k8s/components/**`,
    `k8s/overlays/push/**` and fails while the node is stopped.
  - *pull*: Argo CD syncs `k8s/overlays/gitops` from `main`.
  - Both use the image digest in the shared component `k8s/components/lab-api-image`,
    bumped by a bot PR (`scripts/bump-image.sh`, branch `bot/image-*`), not by hand.
- **Kustomize layout.** `k8s/base` (app) + `k8s/namespace-base` (guardrails) →
  `k8s/namespaces/<name>` (Namespace, LimitRange, Quota, NetworkPolicies, RBAC; applied
  by an admin) and `k8s/overlays/<name>` (what the deployer applies). Guardrail/RBAC kinds
  in an overlay fail `make k8s`.
- **Argo CD app-of-apps** (core mode, no UI/API server). `k8s/platform/argocd-apps` holds
  `root` (syncs that directory, itself included), the AppProjects `platform` and `gitops`,
  and one Application per `k8s/platform/*` component: argocd itself, cert-manager +
  cluster-issuers, external-secrets + secret-stores (SSM, usable from `monitoring` only),
  monitoring (Alloy + kube-state-metrics → Grafana Cloud), system-upgrade + upgrade-plans
  (K3s upgrades by Plan). Self-heal reverts `kubectl edit`s; change git instead.
  Upstream manifests sit in `vendor/` directories; change them with patches in the
  component's `kustomization.yaml`, never by editing `vendor/`.

## Invariants `make k8s` enforces

Read the header of `scripts/render-k8s.sh` before adding any k8s object. Among others:
images pinned by digest; requests and limits on every container; one PDB, HPA, LimitRange
and ResourceQuota per app namespace; Ingress only on Traefik with TLS from a known
ClusterIssuer; default-deny NetworkPolicy; the push deployer's Role covering every kind in
its overlay; each AppProject's destinations and kind whitelists **equal** to what its
Applications render; a namespace that isn't PSA `restricted` needs the annotation
`k3s-gitops-lab/pod-security-exception` and `warn: restricted`.

## Gotchas

- A new script loses its executable bit unless you `chmod +x` it before `git add`.
- Merging a change under the deploy-push paths while the node is stopped turns `main`'s
  deploy red: merge those with the node running.
- Never print SSM values (Tailscale, DuckDNS, GitHub App, Grafana, node identity): pass
  them through pipes and refer to them by name. The repo is public: no email addresses.
- `docs/learning/` holds a note per issue with the reasoning and verification behind each
  component; read the relevant one before changing that component.
