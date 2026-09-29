# 9 · Platform stack: network foundation, backend, default tags

> Issue: #9 (1.2) · Phase 1

## What
`terraform/platform/` is the permanent, free layer the instance runs in: a VPC with one
public subnet, an internet gateway and route table, and the VPC's default security group
locked down. It stores its state in the bootstrap bucket (`platform/terraform.tfstate`)
with S3 locking, and stamps four default tags on everything it creates.

Later tasks add to it: the instance's security group (#11), IAM and SSM (#12), the
nightly auto-stop schedule (#62).

## Why
**Two stacks, not one.** The instance is stopped when idle and rebuilt weekly; the
network, IAM and SSM parameters cost nothing and should never move. Putting them in
separate stacks means destroying the instance stack *cannot* touch them: that stack's
state does not know they exist.

Alternatives considered:
- **One stack, `terraform destroy -target=aws_instance...`** — works, but HashiCorp
  documents `-target` as "for exceptional situations, not routine operations", and one
  mistyped target can take the network with it.
- **AWS's default VPC** — exists in every region and would work, but it is implicit,
  shared by anything else launched in the account, and not code. Our own VPC is free and
  reviewable.
- **Private subnet + NAT Gateway** — the textbook layout, but a NAT Gateway is ~$33/month
  (README "Never create"). The instance sits in a public subnet with its own public IPv4
  and an explicit security group instead; admin access goes over Tailscale (#13).

## How it works
```
internet ── internet gateway ── route table (0.0.0.0/0 → igw)
                                      │
                   VPC 10.42.0.0/16 ──┴── public subnet 10.42.1.0/24 (eu-central-1a)
                                            └─ instance gets a public IPv4 at launch (#10)
```
- **`map_public_ip_on_launch`**: an instance started here gets a public IPv4 address from
  AWS's pool. It is released when the instance stops, so it only costs money while the
  instance runs. An Elastic IP would keep the same address but bills even while stopped.
- **Route table**: `10.42.0.0/16 → local` (automatic) and `0.0.0.0/0 → internet gateway`.
  That second route is what makes the subnet "public".
- **Default security group**: every VPC gets one that allows all traffic between its
  members, and anything launched without an explicit group lands in it.
  `aws_default_security_group` with no rule blocks tells Terraform to adopt it and
  **remove every rule** (CIS AWS Foundations benchmark). Terraform does not create or
  delete this group; it only manages its rules.
- **Default tags**: `Project`, `Stack`, `ManagedBy`, `Repo`, set once in the provider and
  merged into every resource's `tags_all`. They make cost reports and "what is this?"
  questions answerable, and let later tooling find project resources.

## Implementation
| File | Contents |
|---|---|
| `versions.tf` | Terraform `>= 1.15.0`, AWS `~> 6.66`, backend key `platform/terraform.tfstate`, `use_lockfile` |
| `providers.tf` | region, `allowed_account_ids`, default tags with `Stack = "platform"` |
| `variables.tf` | account id, region, AZ `eu-central-1a`, CIDRs |
| `network.tf` | VPC, public subnet, internet gateway, route table + association, default SG lockdown |
| `outputs.tf` | `vpc_id`, `public_subnet_id`, `availability_zone`, `region` for the instance stack |
| `terraform/check_default_tags.py` | reusable check: fails if any taggable resource in a stack's state lacks a default tag |

Also: Dependabot's `terraform` entry now watches `bootstrap`, `platform` and `instance`
(the last one appears in #10), and the README describes the three stacks.

Cost: $0. VPCs, subnets, internet gateways, route tables and security groups have no
hourly charge.

## Verification
| Check | Result |
|---|---|
| Plan | 6 to add, 0 change, 0 destroy |
| Default security group | 0 inbound / 0 outbound rules (AWS API) |
| Subnet | `10.42.1.0/24`, `eu-central-1a`, public IP on launch `True` |
| Routes | `10.42.0.0/16 → local`, `0.0.0.0/0 → igw-…` |
| NAT gateways in the region | 0 |
| Default tags | every taggable resource has all four tags (platform and bootstrap stacks); the route table association cannot carry tags |
| **Tag check, negative control** | a copy of the state with `Repo` removed from the VPC: `MISSING aws_vpc.main ['Repo']`, exit 1 |
| Lock during plan | `platform/terraform.tfstate.tflock` present during the plan, gone after; plan: "No changes" |

## Gotchas
- **"Known after apply" for the default SG's rules.** The plan cannot show that the rules
  will be emptied, because Terraform only learns the existing rules at apply time. The AWS
  API check afterwards is the proof.
- **A public subnet is not a public instance.** Reachability is decided by the instance's
  security group (#11): only 80/443 inbound, no 22 or 6443.
- **The public IP changes on every start.** Anything pointing at it (sslip.io hostname,
  TLS certificate) must follow; admin access uses the stable Tailscale name instead.
- **Python 3.9 f-strings** cannot contain backslashes inside `{...}`; the first version of
  the tag check failed on that. The committed script avoids f-strings with escapes.

## Further reading
- [VPC: internet gateways and public subnets](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [Default security groups](https://docs.aws.amazon.com/vpc/latest/userguide/default-security-group.html)
- [Terraform: aws_default_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group)
- [Terraform: resource targeting is for exceptional situations](https://developer.hashicorp.com/terraform/cli/commands/plan#resource-targeting)
- [AWS provider default_tags](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/resource-tagging)
