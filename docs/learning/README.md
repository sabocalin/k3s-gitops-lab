# Learning notes

One note per task: what it is, why the project needs it, how it works, how it was
verified, and what surprised us. New notes start from [`_template.md`](_template.md).

| Issue | Note | Phase |
|---|---|---|
| #2, #8 | [Terraform bootstrap stack (state bucket, budget, contacts)](8-terraform-bootstrap.md) | 0 / 1 |
| #3 | [Dependabot version updates](3-dependabot.md) | 0 |
| #4 | [Pin all GitHub Actions to a commit SHA](4-pin-actions.md) | 0 |
| #5 | [README: cost model and "never create" list](5-readme-cost-model.md) | 0 |
| #6 | [Ruleset on `main`](6-main-ruleset.md) | 0 |
| #9 | [Platform stack: network foundation, backend, default tags](9-platform-stack.md) | 1 |
| #10, #11 | [EC2 instance and its security group](10-instance-and-security-group.md) | 1 |
| #12 | [Node IAM role and the Tailscale secret in SSM](12-node-iam-and-secret.md) | 1 |
| #13 | [Tailscale on first boot](13-tailscale-on-boot.md) | 1 |
| #14 | [Ansible: swap and K3s over Tailscale SSH](14-ansible-k3s.md) | 1 |
| #15 | [Local kubeconfig over Tailscale](15-kubeconfig-over-tailscale.md) | 1 |
| #16 | [GitHub OIDC: plan role (PRs) and apply role (main)](16-github-oidc-roles.md) | 1 |
| #17 | [Terraform checks in CI: fmt, validate, tflint, trivy](17-terraform-lint.md) | 1 |
| #19 | [FastAPI scaffold: /health, /ready, /metrics](19-fastapi-scaffold.md) | 2 |
| #20 | [Multi-stage Dockerfile: distroless, non-root, digest-pinned](20-dockerfile.md) | 2 |
| #21 | [App CI: ruff and pytest on every PR](21-app-ci.md) | 2 |
| #22 | [Native arm64 image build, pushed to GHCR by git SHA](22-image-build.md) | 2 |
| #23 | [Image vulnerability scan: fail on fixable HIGH/CRITICAL](23-image-scan.md) | 2 |
| #24 | [SBOM and build provenance attestations](24-attestations.md) | 2 |
| #25 | [Keyless cosign signing](25-cosign-signing.md) | 2 |
| #27 | [Kustomize base and overlays: push and gitops namespaces](27-kustomize-layout.md) | 3 |
| #28 | [Deployment: 3 replicas, zero-downtime rolling updates](28-rollout.md) | 3 |
| #90 | [K3s pod network off the VPC range; pod DNS fixed](90-cluster-network-ranges.md) | 1 |
| #29 | [Liveness, readiness and startup probes](29-probes.md) | 3 |
| #30 | [Requests, limits, LimitRange and ResourceQuota](30-resources.md) | 3 |
| #31 | [securityContext and Pod Security "restricted"](31-security-context.md) | 3 |
| #32 | [PodDisruptionBudget minAvailable 2](32-pod-disruption-budget.md) | 3 |
| #33 | [NetworkPolicy: default deny, allow Traefik to the app](33-network-policy.md) | 3 |
| #34 | [HorizontalPodAutoscaler on CPU (min 3, max 5)](34-hpa.md) | 3 |
| #35 | [Service + Ingress on K3s's built-in Traefik](35-ingress.md) | 3 |
| #36 | [A fixed hostname for a changing IP: DuckDNS, updated at boot](36-dynamic-dns.md) (part 1) | 3 |
| #36 | [cert-manager + Let's Encrypt HTTP-01 (staging, then production)](36-cert-manager.md) (part 2) | 3 |
| #38 | [Push deploys: a namespace-scoped ServiceAccount and Role](38-deployer-rbac.md) | 4 |
| #39 | [Push deploys: GitHub Actions joins the tailnet and runs kubectl apply](39-push-deploy.md) | 4 |
| #40 | [Argo CD core install (and why the node is now a t4g.medium)](40-argocd-core.md) | 4 |
| #47 | [Memory headroom before adding ArgoCD and observability](47-memory-headroom.md) | 5 |
| #57 | [AI code review on pull requests](57-ai-review.md) | 0 |
| #61 | [`make start / stop / extend / status / up / down`](61-make-lifecycle.md) | 1 |
| #62 | [Nightly auto-stop (EventBridge Scheduler)](62-nightly-autostop.md) | 1 |
