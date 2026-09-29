# k3s-gitops-lab

Zero-cost K3s on AWS: Terraform, Ansible, FastAPI, GitHub Actions push CD and ArgoCD GitOps.

A learning project that builds a small but complete platform on a single EC2 node,
entirely from code, and then deliberately breaks it. Work is tracked on the
[project board](https://github.com/users/sabocalin/projects/1).

## Architecture

```
internet ──80/443──▶ EC2 t4g.small (K3s)
                       ├─ Traefik ingress ─▶ FastAPI (3 replicas)
                       ├─ cert-manager (Let's Encrypt)
                       └─ ArgoCD (core)

admin ──Tailscale──▶ SSH + Kubernetes API   (no public 22 or 6443)
GitHub Actions ──OIDC──▶ AWS (no stored keys)
GitHub Actions ──Tailscale──▶ Kubernetes API (push deploys)
```

- Infrastructure: Terraform (S3 backend) + Ansible installs K3s.
- Images: built natively for arm64 in GitHub Actions, pushed to GHCR, signed.
- Deploys: two paths to separate namespaces, push (`kubectl apply` from Actions)
  and pull (ArgoCD watching this repo).

## Cost model

Target: **near $0**, about $1.35–2.10/month. The AWS account is on the **paid plan with no
credits** (the Free plan was not available for it), so nothing caps spending: the design
keeps billable resources small and running only when used. Prices are approximate
eu-central-1 on-demand list prices, before VAT; check the pricing pages.

| Resource | Free allowance | Cost |
|---|---|---|
| EC2 `t4g.small` | 750 h/month free trial until **2026-12-31** (every customer) | $0 until then; ~$0.019/h after (~$14/month 24/7) |
| EBS gp3, 12 GB | none | ~$1.14/month, **billed even while the instance is stopped** |
| Public IPv4 address | none | ~$0.005/h (~$3.60/month) while attached; $0 while stopped |
| Data transfer out | 100 GB/month | ~$0.09/GB above that |
| S3 (Terraform state) | — | Cents |
| SSM Parameter Store (standard, AWS-managed key) | Free | Free |
| EventBridge Scheduler (nightly auto-stop) | Free monthly invocations | Free |
| AWS Budgets (one budget, no actions) | Free | Free |
| GitHub Actions, GHCR | Free for public repos and public packages | — |
| Tailscale, Grafana Cloud, Gemini API | Free personal / free tiers | — |

**Running model: stop when idle.** `make stop` / `make start` around each session, a
nightly auto-stop at 23:00 Europe/Bucharest as a safety net, and a weekly
destroy-and-rebuild drill that proves everything comes back from git.

| Usage (~40 h/month running) | Until 2026-12-31 | After |
|---|---|---|
| **Stop when idle** (chosen) | ~$1.35/month | ~$2.10/month |
| Destroy when idle | ~$0.26/month | ~$1.05/month |
| Running 24/7 (for comparison) | ~$4.80/month | ~$19/month |

Notes:

- **Nothing caps spend on a paid account.** The realistic risk is leaked credentials
  (someone mining crypto on your bill), not this project's resources. Mitigations: no
  long-lived access keys anywhere (`aws login` locally, OIDC in CI), MFA on root and
  the admin user, and the budget alert.
- **Public IPv4 costs only while the instance runs.** Stopping releases the
  auto-assigned address (a new IP, and so a new sslip.io hostname, on every start). An
  Elastic IP would keep the address stable but bills ~$3.60/month even while stopped.
- **Egress** comes from responses to users, Alloy shipping metrics and logs to
  Grafana Cloud, and Tailscale traffic. Pulling images from GHCR is inbound and
  free. Expected volume is far below 100 GB/month.
- **Guardrail:** a $5/month AWS Budgets alert, on actual spend ≥ 80% and forecasted
  spend ≥ 100%. Any alert means something unplanned is running.
- **2026-12-31:** the `t4g.small` trial ends; decide stop-when-idle vs 24/7 (#53).

## Never create

These are easy to add by accident and break the near-$0 target.

| Resource | Approx. cost | Use instead |
|---|---|---|
| Application / Network Load Balancer | ~$16/month + usage | K3s built-in Traefik + ServiceLB |
| NAT Gateway | ~$33/month + $0.045/GB | Public subnet, instance has its own public IP |
| EKS control plane | ~$73/month | K3s |
| Idle Elastic IP | ~$3.60/month | Auto-assigned public IP |
| Route 53 hosted zone | $0.50/month | `<ip>.sslip.io` wildcard DNS |
| Customer-managed KMS key | $1/month | AWS-managed keys (`aws/ssm`, `aws/s3`) |
| VPC interface endpoints | ~$7/month per AZ | Public AWS endpoints over the instance's public IP |

## Design notes

### Terraform state locking

The S3 backend uses native locking (`use_lockfile = true`, Terraform 1.10+).
DynamoDB-based locking (`dynamodb_table`) is deprecated since Terraform 1.11.
To migrate an existing backend, set `use_lockfile = true` alongside
`dynamodb_table` and run `terraform init -reconfigure`; once every user and
pipeline runs Terraform 1.10+, remove `dynamodb_table`, re-init, and delete the table.
