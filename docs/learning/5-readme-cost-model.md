# 5 · README: cost model and "never create" list

> Issue: #5 · PR: #55 · Phase 0

## What
The README's **Cost model** (what each resource costs, what the free allowance is) and
**Never create** list (resources that break the $0 target, with the free alternative).

## Why
The project has a hard constraint: **$0/month**. AWS makes it easy to spend money by
accident: one checkbox in a wizard, one Terraform module with a load balancer inside,
one idle Elastic IP. Writing the cost model *before* any resource exists turns the
constraint into a checklist you apply to every Terraform change.

It also trains a habit that matters in real jobs: knowing what a design costs before
building it.

Alternatives considered:
- **Rely on the budget alert only** — an alert tells you after money is spent (see
  Gotchas), it does not prevent it.

## How it works
AWS billing is metered per resource, per hour or per GB, and the free allowances are
separate programs with different rules:

- **Free trials** (e.g. `t4g.small`, 750 h/month until 2026-12-31): open to every account.
- **Free tier** (12 months or credits, depending on account age): varies per account;
  check Billing → Free Tier.
- **Always free** items (e.g. SSM Parameter Store standard parameters, one Budgets budget).

Three billing facts drive most of the design (see also the update below):
1. **Every public IPv4 address costs money** (~$3.60/month), attached or not, since
   AWS started charging for them in February 2024. That is why the design has exactly
   one public IP and no Elastic IP.
2. **Inbound data is free; outbound (egress) is metered** after 100 GB/month.
   Pulling images from GHCR into EC2 is inbound, so it is free.
3. **Managed "glue" is expensive**: load balancers, NAT gateways, EKS control planes and
   VPC interface endpoints bill per hour even when idle. K3s + Traefik + a public subnet
   replace all of them.

## Implementation
`README.md` sections:
- **Architecture**: EC2 → K3s → Traefik → app; admin access only over Tailscale.
- **Cost model**: one row per resource with free allowance and cost if not covered,
  plus notes on public IPv4, egress sources, the $1 budget alert and the 2026-12-31 date.
- **Never create**: ALB/NLB, NAT Gateway, EKS, idle Elastic IP, Route 53 hosted zone,
  customer-managed KMS key, VPC interface endpoints; each with approximate cost and
  the $0 alternative.
- **Design notes → Terraform state locking**: why `use_lockfile` and not DynamoDB
  (deprecated since Terraform 1.11), and how to migrate an existing backend.

## Verification
Documentation, so there is no command to run. Prices were taken from AWS public
pricing and are approximate us-east-1 on-demand figures; confirm them for your region
before relying on them.

## Update (2026-09-29): paid plan, no credits
The AWS account could not use the Free plan (the owner's identity is linked to other
accounts), so it is on the paid plan with **no credits**. Opening another account under
a different name to get around that would break AWS's terms and was rejected.

What changed:
- **Target** moved from "$0" to "near $0" (~$1–2/month).
- **Disk** 30 GB → 12 GB: EBS bills every hour it exists, even while the instance is
  stopped, and there is no free allowance on this account.
- **Running model: stop when idle**, with a nightly auto-stop (EventBridge Scheduler,
  #62) as the safety net and a weekly rebuild drill (#64). Destroy-when-idle is cheaper
  (~$0.26/month) but makes every session start with a 5–10 minute rebuild; the ~$1/month
  difference buys a 1-minute resume, and the weekly drill keeps the automation honest.
- **Budget** $1 → $5/month with actual (80%) and forecast (100%) alerts (#2).
- **Main risk re-framed:** nothing caps spending, so leaked credentials matter more
  than resource choices. No long-lived keys anywhere, MFA everywhere.

## Gotchas
- **Budgets alert with a delay.** AWS Budgets data refreshes a few times a day, so an
  alert can arrive hours after the spend started. It is a safety net, not a brake.
- **"Free tier eligible" in the console is per account.** A resource labelled eligible
  can still bill if your account's free tier expired or was never granted.
- **Stopping the instance frees its auto-assigned public IP** (no charge while stopped),
  but you get a different IP on start. Anything pointing at the old IP (sslip.io
  hostname, Let's Encrypt certificate) has to follow.
- **Deleting is part of the cost model.** The trial ends 2026-12-31; `terraform destroy`
  or a decision to pay (#53) must happen before then.

## Further reading
- [Amazon EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [AWS public IPv4 address charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)
- [AWS Free Tier](https://aws.amazon.com/free/)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Managing costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
