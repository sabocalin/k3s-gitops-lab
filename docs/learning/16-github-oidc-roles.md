# 16 · GitHub OIDC: plan role (PRs) and apply role (main)

> Issue: #16 (1.9) · Phase 1

## What
GitHub Actions can now get AWS credentials without any stored key. An identity provider
for GitHub's OIDC issuer plus two IAM roles: **plan** (pull requests: read-only) and
**apply** (only jobs in the `production` environment, which GitHub allows on `main` only:
the node and its schedules). A check workflow proves both from GitHub's side.

## Why
Later work runs in CI: plan on PRs, the "Start lab" button (#63), the weekly rebuild
(#64). An access key in repo secrets would be long-lived and leakable, and on a paid
account with no spending cap a leaked key is the realistic way to run up a bill.

Alternatives considered:
- **Access keys in repo secrets** — long-lived; one leak gives an attacker the account.
- **One role for everything** — a pull request would get write access.
- **`AdministratorAccess` on the apply role** — anything merged to `main` could own the account.
- **Apply role that can also manage IAM and the VPC** (as the issue first said) — a role
  that can edit IAM can grant itself more. Those changes stay a laptop apply with MFA.

## How it works
```
GitHub job ──(1) asks GitHub for an OIDC token: aud=sts.amazonaws.com,
             sub=repo:sabocalin/k3s-gitops-lab:pull_request | …:environment:production
         ──(2) sts:AssumeRoleWithWebIdentity(token, role)
AWS STS  ──(3) checks the signature against the identity provider
              (token.actions.githubusercontent.com), then the role's trust policy:
              aud and sub must match EXACTLY (StringEquals)
         ──(4) returns credentials valid for 1 hour
```
- **`sub` is the whole security boundary.** The plan role accepts `…:pull_request`. The
  apply role accepts only `…:environment:production`. A job gets that subject only when
  it declares `environment: production`, and GitHub runs such a job only on branches the
  environment allows (`main`). `main` itself only changes through reviewed, signed PRs (#6).
- **Pull requests from forks** get no OIDC token at all, so strangers' PRs cannot assume
  even the plan role.
- **Where the roles live:** the bootstrap stack, applied only from the laptop. Neither role
  has any IAM write, so CI cannot widen its own permissions.

### The plan role
- `ReadOnlyAccess` (AWS-managed): enough for `terraform plan` of every stack.
- `s3:PutObject`/`DeleteObject` on `*.tflock` only: S3-native locking (`use_lockfile`)
  writes a lock file even during a plan. The state files stay read-only.

### The apply role: the instance stack only
`ReadOnlyAccess` for refresh and plan, plus an inline policy where every write is tied to
the project:
- **RunInstances** is authorized once per resource it touches, so it has one statement per
  resource type. The instance needs tag `Project=k3s-gitops-lab` and type `t4g.small` or
  `t4g.medium` (a cost guard). The disk needs the tag too. Subnet and security group must
  carry the tag, and the image must be owned by Canonical (`099720109477`).
- **Start/Stop/Terminate/Modify/tag**: only on instances and volumes tagged
  `Project=k3s-gitops-lab`. Tagging otherwise only while launching (`ec2:CreateAction`).
- **`iam:PassRole`**: the node role only to EC2, the autostop role only to Scheduler. No
  creating or editing roles.
- **Scheduler**: create, update and delete only schedules named `k3s-gitops-lab-*`
  (nightly stop, lease).
- **State**: write `instance/*` in the state bucket; the platform state is read-only.

### Both roles: never the secret
`ReadOnlyAccess` includes `ssm:GetParameter` on every parameter, so both roles carry
**explicit denies**: on `/k3s-gitops-lab/*` parameters, and on `kms:Decrypt` through SSM.
An explicit Deny beats any Allow. The decrypt deny also covers reading a parent path.

## Implementation
- `terraform/bootstrap/github_oidc.tf`: the identity provider (no thumbprint: AWS validates
  GitHub's certificate chain itself), two roles (`max_session_duration` 1 h), the
  `ReadOnlyAccess` attachments, inline policies. Applied from the laptop: 7 added.
- GitHub: environment `production` with a custom deployment branch policy: `main` only.
- `.github/workflows/aws-oidc-check.yml`: the checks below; actions pinned by SHA,
  `permissions: {}` at the top and only `id-token: write` per job.
- `README.md`: "CI access to AWS" section.

## Verification
**IAM policy simulator** (31 cases, both roles):

| Check | Result |
|---|---|
| apply: RunInstances, `t4g.small`, tagged | allowed |
| apply: RunInstances `c5.4xlarge` / without the tag / non-Canonical image | implicitDeny ×3 |
| apply: Terminate tagged / untagged instance | allowed / implicitDeny |
| apply: open a security-group port, create a VPC, create a role, edit its own policy | implicitDeny ×4 |
| apply: PassRole node→EC2 / node→Lambda / its own role | allowed / implicitDeny / implicitDeny |
| apply: schedule `k3s-gitops-lab-lease` / any other name | allowed / implicitDeny |
| apply: write instance state / platform state / modify the budget | allowed / implicitDeny / implicitDeny |
| plan: Describe, read state, write `.tflock` | allowed |
| plan: write state, RunInstances, StopInstances | implicitDeny ×3 |
| plan: public Ubuntu AMI parameter | allowed |
| **both: the Tailscale secret; kms:Decrypt via SSM** | **explicitDeny** |

One expectation was wrong, in the safe direction: `GetParametersByPath` on `/` was
implicitly denied (I expected `ReadOnlyAccess` to allow it).

**From GitHub** (`aws-oidc-check.yml`): see the table filled in from the PR and the
`main` runs below.

## Gotchas
- **The environment, not AWS, checks the branch.** An `environment:production` token does
  not say which branch it came from, so the environment's branch policy is part of the
  security boundary. Do not loosen it to "all branches".
- **ReadOnlyAccess reads parameters.** Any role built on it needs the secret denies.
- **RunInstances is many authorizations in one call** (instance, volume, ENI, subnet,
  security group, image); a missing statement fails the whole launch with one
  `UnauthorizedOperation`.

## Further reading
- [GitHub: OpenID Connect in AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [GitHub: OIDC token claims (`sub` formats)](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect#example-subject-claims)
- [AWS: creating a role for GitHub OIDC](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html)
- [EC2 RunInstances: resource-level permissions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html)
- [GitHub environments: deployment branches](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment#deployment-branches-and-tags)
