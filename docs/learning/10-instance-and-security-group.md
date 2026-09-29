# 10 + 11 · EC2 instance and its security group

> Issues: #10 (1.3), #11 (1.4) · Phase 1

## What
- **#11** — `aws_security_group.node` in the **platform** stack: inbound TCP 80 and 443
  from anywhere, outbound unrestricted. No 22, no 6443.
- **#10** — `terraform/instance`: one `t4g.small` running Ubuntu 24.04 arm64 in the public
  subnet, with that security group, a 12 GB encrypted gp3 disk, IMDSv2 only, and CPU
  credits set to `standard`. It is the only resource in the project that costs money, and
  it is **stopped when idle**.

## Why
The instance is the K3s node. Every choice below is either a security default that is
cheaper to set now than to retrofit, or a cost trap closed before it can bite.

Alternatives considered:
- **Fixed AMI id in code** — reproducible, but goes stale. The SSM public parameter gives
  Canonical's current image; `ignore_changes = [ami]` keeps it from forcing replacement.
- **SSH key pair "just in case"** — would need port 22 open to be useful; admin access
  comes over Tailscale (#13), and until then the AWS API is enough.
- **Inline `ingress {}` blocks in the security group** — work, but every rule change
  rewrites the whole group in state. Separate `aws_vpc_security_group_*_rule` resources
  change one rule at a time.
- **Security group in the instance stack** — it is free and permanent; it belongs with the
  network in `platform`, so destroying the instance leaves it alone.

## How it works
### Cost traps closed
| Trap | Default | Setting here |
|---|---|---|
| **Burstable CPU billing** | `t4g` (and this account's default) is `unlimited`: sustained CPU above the baseline is billed as surplus credits, possibly outside the free trial | `cpu_credits = "standard"`: throttle instead of charge |
| **Disk billed while stopped** | whatever size you pick bills every hour it exists | 12 GB gp3 (~$1.14/month) |
| **Public IPv4 while idle** | an Elastic IP bills while stopped | auto-assigned address, released on stop (verified: `None` while stopped, 0 Elastic IPs) |

### Security defaults
- **IMDSv2 required** (`http_tokens = "required"`): the instance metadata service only
  answers requests that first obtain a session token with a `PUT`. That blocks the
  classic SSRF trick of making a web app fetch `169.254.169.254` and leak the instance's
  credentials.
- **Hop limit 1**: the token response cannot cross an extra network hop, so a container
  behind the node's network stack cannot fetch it. #54 (External Secrets) raises this to 2
  only if pods must use the node's role, as a documented trade-off.
- **Encrypted root volume** with the AWS-managed EBS key: free.
- **No key pair**, **no port 22**.

### Reading the port tests
A security group **drops** packets it does not allow: the client waits, then **times
out**. When the group allows a port but nothing listens there, the OS answers with a TCP
reset: the client sees **connection refused** immediately. So:
- timeout on 22/6443 = blocked by the security group (what we want);
- refused on 80/443 = allowed through and reached the machine (Traefik will listen there).

A timeout alone could also be your own network blocking the port, so the test needs a
control: the same ports to a host known to answer.

### Stop vs Terraform
`aws_instance` does not manage "running vs stopped". Stopping with the AWS CLI makes
Terraform notice only that `public_ip` became empty; it plans **no** resource change and
never starts the instance again. That is what lets `make stop` / `make start` (#61) use the
AWS CLI directly.

## Implementation
- **`terraform/platform/security_group.tf`**: group + `http`, `https` ingress rules +
  one all-protocols egress rule; output `node_security_group_id`.
- **`terraform/instance/`**:
  - `main.tf`: `terraform_remote_state` reads the platform outputs (subnet, security
    group); `aws_ssm_parameter` resolves the AMI; `aws_instance` with the settings above;
    `ignore_changes = [ami]`.
  - `outputs.tf`: `instance_id`, `public_ip` and `sslip_hostname` (both `null` while
    stopped), `ami`.
  - Same backend (key `instance/terraform.tfstate`), account guard and default tags
    (`Stack = "instance"`) as the other stacks.

## Verification
| Check | Result |
|---|---|
| Dry-run launch before building | `DryRunOperation` (account allowed to launch) |
| Image | `ubuntu-noble-24.04-arm64-server-20260923`, owner `099720109477` (Canonical) |
| Instance (API) | `t4g.small`, `arm64`, `eu-central-1a`, IMDSv2 `required`, hop limit `1`, no key pair |
| CPU credits | `standard` (account default for t4g is `unlimited`) |
| Root volume | `gp3`, 12 GB, encrypted |
| Boot | console: `Ubuntu 24.04.5 LTS`, cloud-init finished; status checks `ok ok` |
| Tags | 0 untagged (`check_default_tags.py`) |
| Security group rules | in: tcp 80, tcp 443 from 0.0.0.0/0; out: all |
| **Ports 22 and 6443** | **timed out** (dropped by the security group) |
| Ports 80 and 443 | refused in 0 s (allowed; nothing listening yet) |
| Controls from the laptop | github.com:22, portquiz.net:6443 and :80 succeed, so the timeouts are not the local network |
| Stop | stopped; public IP `None`; plan shows no resource change, only outputs going to `null` |

## Gotchas
- **EC2 rejects apostrophes in security-group rule descriptions.** `Let's Encrypt` failed
  with `InvalidParameterValue: Invalid rule description` (allowed characters:
  `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`). The other rules had already been created, leaving a
  partial apply; Terraform simply planned the missing rule again.
- **`--dry-run` is not validation.** The same rule sent with `--dry-run` answered "Request
  would have succeeded". EC2 dry runs check *permissions*, not every parameter. The real
  error came from applying a reviewed plan.
- **Silent failures in a wait loop.** The first "wait for port 80 to be refused" loop never
  matched because macOS `nc` without `-v` prints nothing on failure; `grep` had nothing to
  find. Always look at the raw output of the check you rely on.
- **`-target` + `-auto-approve` is a blind apply.** An attempt to re-run only the failed
  rule that way was blocked. The right path was a fresh saved plan, read, then applied.
- **A template `.gitignore` hid the whole stack.** The Python template GitHub added at repo
  creation ignores `instance/` (a Flask folder), so `terraform/instance/` was silently
  ignored and `git add` skipped it. `git check-ignore -v <path>` names the exact rule;
  fixed with `!terraform/instance/`. Always check `git status` after adding new folders.
- **Output of a stopped instance.** `public_ip` becomes an empty string; without handling
  it, the hostname output turned into `.sslip.io`. Outputs now return `null` instead.

## Further reading
- [EC2 burstable performance: standard vs unlimited](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-unlimited-mode.html)
- [Use IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-existing-instances.html)
- [Find an Ubuntu AMI with SSM Parameter Store](https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/)
- [Security group rules](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html)
- [Terraform: aws_vpc_security_group_ingress_rule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule)
