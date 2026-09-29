# 12 · Node IAM role and the Tailscale secret in SSM

> Issue: #12 (1.5) · Phase 1

## What
- An IAM role for the node (`k3s-gitops-lab-node`) with an instance profile, attached to
  the instance. It can do exactly two things: read **one** SSM parameter, and register
  with Session Manager for break-glass shell access.
- One SSM **SecureString** parameter, `/k3s-gitops-lab/tailscale/oauth-client-secret`,
  holding a Tailscale OAuth client secret. **Created by hand, not by Terraform**, so its
  value never reaches Terraform state.

## Why
The node must join the tailnet on boot (#13) without a human, which means it needs a
credential. That credential must not live in the repo (public), in Terraform state (holds
every value Terraform touches), or in user_data (readable by anyone who can describe the
instance, and logged by cloud-init).

**Why an OAuth client secret, not an auth key:**

| | Auth key | OAuth client secret |
|---|---|---|
| Expiry | 90 days at most | none (revocable) |
| Automation | weekly rebuild breaks when it expires | works indefinitely |
| Requirement | none | the device must be tagged (`tag:k3s`) |

Tailscale accepts an OAuth client secret wherever it accepts an auth key, as long as the
device requests a tag the client may assign.

**Why a tag:** a tagged device belongs to the tag, not to a user, so its key does not
expire with a user's login session. Only the tag's owners (`autogroup:admin`) and OAuth
clients granted the tag can apply it.

Alternatives considered:
- **Terraform-managed `aws_ssm_parameter`** — convenient, but a refresh reads the
  decrypted value back into state. (Write-only attributes avoid that, but the value still
  has to pass through a Terraform variable.)
- **Secret in user_data** — visible via `describe-instance-attribute` and in cloud-init logs.
- **AWS Secrets Manager** — $0.40/secret/month; SSM standard parameters are free.
- **`AmazonSSMManagedInstanceCore` for Session Manager** — the usual shortcut, but it
  also allows `ssm:GetParameter(s)` on **every** parameter, which would break "read one
  parameter and nothing else".

## How it works
```
boot (#13) ─▶ instance profile ─▶ temporary role credentials from IMDSv2
            ─▶ ssm:GetParameter(oauth-client-secret, WithDecryption)
            ─▶ SSM decrypts with the AWS-managed aws/ssm key
            ─▶ tailscale up --authkey <secret> --advertise-tags=tag:k3s
```
- **Instance profile**: the container that attaches a role to an EC2 instance. The
  instance gets short-lived credentials for the role from the metadata service (IMDSv2,
  hop limit 1), rotated automatically.
- **Decryption without `kms:Decrypt`**: the AWS-managed `aws/ssm` key's key policy already
  lets principals in the account use it *through SSM* (`kms:ViaService`). A
  customer-managed key would need an explicit grant, and cost $1/month.
- **Session Manager**: the SSM agent (preinstalled on Ubuntu AMIs) connects *out* to
  `ssmmessages`, so a shell works with no inbound port and no key pair. The five
  `ssm:UpdateInstanceInformation` / `ssmmessages:*Channel` actions are the minimum; they do
  not support resource-level restrictions, hence `*`.

## Implementation
- **`terraform/platform/iam_node.tf`**: trust policy (only `ec2.amazonaws.com`), inline
  policy (`ReadTailscaleSecret` on one ARN, `SessionManager`), instance profile. Outputs:
  `node_instance_profile_name`, `node_role_arn`, `tailscale_secret_parameter`.
- **`terraform/instance/main.tf`**: `iam_instance_profile` from the platform outputs (an
  in-place change, no replacement).
- **Tailscale** (admin console, by hand): tag `tag:k3s` owned by `autogroup:admin`; an
  OAuth client with only **Keys → Auth Keys: Write**, restricted to `tag:k3s`.

### Runbook: store or rotate the secret
1. Tailscale admin → Settings → OAuth clients → Generate (Auth Keys: Write, `tag:k3s`).
   The secret is shown once.
2. Copy the secret, then:
   ```sh
   pbpaste | tr -d '\n' | AWS_PROFILE=personal aws ssm put-parameter \
     --region eu-central-1 --type SecureString \
     --name /k3s-gitops-lab/tailscale/oauth-client-secret \
     --tags Key=Project,Value=k3s-gitops-lab \
     --value file:///dev/stdin
   ```
   To rotate, drop `--tags` and add `--overwrite`.
3. Clear the clipboard. Revoke the old OAuth client in Tailscale.

`file:///dev/stdin` keeps the secret out of the process list (a `--value "$(pbpaste)"`
argument would be visible to `ps` while the command runs); `tr -d '\n'` removes a trailing
newline that would otherwise become part of the secret.

## Verification
| Check | Result |
|---|---|
| Planned policy | trust: `ec2.amazonaws.com`; `ssm:GetParameter` on one ARN; 5 Session Manager actions |
| Profile attached | `arn:aws:iam::466558795290:instance-profile/k3s-gitops-lab-node` (in place) |
| Simulator: GetParameter on the secret | **allowed** |
| Simulator: another parameter, `GetParameters`, `GetParametersByPath` | implicitDeny |
| Simulator: `PutParameter` on the secret, read state bucket, `ec2:StopInstances` | implicitDeny |
| Simulator: Session Manager channel | allowed |
| stdin mechanism (throwaway parameter) | round-trip exact, no trailing newline; test parameter deleted |
| Parameter | SecureString, `alias/aws/ssm`, Standard, v1, tagged; ARN matches the policy |
| `tskey` in the three Terraform states | 0, 0, 0 |
| `tskey` in the repo (outside these docs) | none |
| Instance user_data | none |

The value itself was never read during verification. Its correctness is proven in #13,
when the node joins the tailnet with it.

## Gotchas
- **`sensitive = true` would not have been enough.** It hides values from output, not from
  state. Keeping the parameter out of Terraform entirely is what keeps it out of state.
- **The policy simulator evaluates policies, not reality.** It proves the role's policy
  allows and denies the right things; it does not prove the instance can reach SSM or that
  the parameter exists. #13 covers the real call.
- **One manual step in an automated project.** The secret is the one thing created by hand;
  it survives `make down` and weekly rebuilds because it lives in SSM, not on the instance.
- **The client ID is not a secret** and is not needed on the node; the secret alone works
  as an auth key.

## Further reading
- [Tailscale OAuth clients](https://tailscale.com/kb/1215/oauth-clients)
- [Tailscale tags](https://tailscale.com/kb/1068/tags)
- [IAM roles for EC2 (instance profiles)](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)
- [SSM Parameter Store SecureString and KMS](https://docs.aws.amazon.com/kms/latest/developerguide/services-parameter-store.html)
- [Session Manager: minimal instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html)
- [IAM policy simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
