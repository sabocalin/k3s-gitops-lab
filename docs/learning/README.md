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
| #57 | [AI code review on pull requests](57-ai-review.md) | 0 |
| #61 | [`make start / stop / extend / status / up / down`](61-make-lifecycle.md) | 1 |
| #62 | [Nightly auto-stop (EventBridge Scheduler)](62-nightly-autostop.md) | 1 |
