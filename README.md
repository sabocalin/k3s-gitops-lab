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

Target: **$0/month**. Prices are approximate us-east-1 on-demand list prices;
check your region.

| Resource | Free allowance | Cost if not covered |
|---|---|---|
| EC2 `t4g.small` | 750 h/month free trial until **2026-12-31** | ~$12/month |
| EBS gp3, ≤30 GB | Free tier or account credits | ~$0.08/GB-month (~$2.40 for 30 GB) |
| Public IPv4 address | Free tier or account credits only | ~$3.60/month per address, attached or idle |
| Data transfer out | 100 GB/month | ~$0.09/GB |
| S3 (Terraform state) | Negligible | Cents |
| SSM Parameter Store (standard, AWS-managed key) | Free | Free |
| AWS Budgets (one budget) | Free | Free |
| GitHub Actions, GHCR | Free for public repos and public packages | — |
| Tailscale, Grafana Cloud | Free personal/free tiers | — |

Notes:

- **Public IPv4 is the one likely charge.** Stopping the instance releases its
  auto-assigned address, so idle time costs nothing. An Elastic IP keeps billing
  while idle.
- **Egress** comes from responses to users, Alloy shipping metrics and logs to
  Grafana Cloud, and Tailscale traffic. Pulling images from GHCR is inbound and
  free. Expected volume is far below 100 GB/month.
- **Guardrail:** an AWS Budgets alert at $1 emails on any spend.
- **2026-12-31:** the `t4g.small` trial ends. Destroy the stack or accept ~$12/month.

## Never create

These are easy to add by accident and break the $0 target.

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
