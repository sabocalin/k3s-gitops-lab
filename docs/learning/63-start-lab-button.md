# 63 · "Start lab" button (workflow_dispatch)

> Issue: #63 (4.9) · Phase 4

## What
A GitHub Actions workflow, `lab`, run by hand from the Actions tab or the GitHub mobile
app. It starts, stops or extends the lab node. It runs `scripts/lab.sh`, the same code as
`make start/stop/extend`, with one-hour AWS credentials from GitHub OIDC for a new,
narrow role: `k3s-gitops-lab-github-lab`. The run's summary shows the public IP, the
sslip.io hostname, DuckDNS and whether `/health` answers.

## Why
Starting the lab needed the laptop: an `aws login` session, Tailscale and `make`. A
phone is enough to start it a few minutes before sitting down, or to stop a node that was
left running.

The role had to be new. The existing `apply` role can launch, resize and terminate
instances (#16), far more than a button needs.

Alternatives considered:
- **Reuse the `apply` role and the `production` environment**: no IAM change, but a
  button press would hold credentials that can terminate the node, and the job would see
  production's secrets (the bot's private key, #41).
- **An AWS Lambda behind a URL, or the AWS console app**: works without GitHub, but it's
  a new endpoint to secure (or a long-lived console login on a phone), and it costs
  something or needs new auth. GitHub already authenticates the user and holds no AWS keys.
- **Start without a lease** (only the three EC2 permissions the issue lists): a node
  started from a phone and forgotten would run until the 23:00 nightly stop (#62). The
  lease costs four scheduler permissions on one named schedule.

## How it works
```
phone / Actions tab ─▶ workflow_dispatch (action: start|stop|extend, lease 1–4 h)
  job in environment "lab" ─── GitHub allows it on main only (deployment branch policy)
    OIDC token: sub = repo:sabocalin@238511101/k3s-gitops-lab@1385841640:environment:lab
    ─▶ sts:AssumeRoleWithWebIdentity: role k3s-gitops-lab-github-lab trusts exactly that sub
    ─▶ scripts/lab.sh <action>   (GITHUB_ACTIONS set: CI mode)
         start:  describe ─▶ start-instances ─▶ wait running ─▶ lease schedule (at +N min,
                 runs as the autostop role) ─▶ IP, sslip.io ─▶ wait for DuckDNS ─▶ /health
         stop:   stop-instances ─▶ delete lease ─▶ wait stopped
         extend: running? ─▶ move the lease
    every message also goes to $GITHUB_STEP_SUMMARY (what the mobile app shows)
```
- **Three things decide who can press the button.** Running a workflow needs write access
  to the repository. The `lab` environment only runs on `main`, so a pushed branch with
  an edited workflow can't use it. The role trusts only the `environment:lab` subject,
  so no other job (production's, a pull request's) can assume it.
- **CI mode in `lab.sh`.**
  - No AWS profile: OIDC puts credentials in the environment.
  - No Tailscale, so K3s isn't checked; the public `/health` is, from the runner, which is
    also how a user reaches the app.
  - Only `start|stop|extend` are allowed.
  - On the laptop, nothing changed.
- **Inputs are choices**, passed to the script as environment variables (`ACTION`,
  `LEASE_MINUTES`) and never pasted into the shell command, so there's no template
  injection. `lab.sh` validates the lease again.

## Implementation
- `terraform/bootstrap/github_oidc.tf`: role `k3s-gitops-lab-github-lab`, one-hour sessions,
  no managed policies. Inline policy `start-stop-lease`:
  - `ec2:DescribeInstances` on `*`: describe calls have no resource-level permissions;
  - `ec2:StartInstances` and `ec2:StopInstances` on instances tagged
    `Project=k3s-gitops-lab` **and** `Stack=instance`;
  - `scheduler:Create/Update/Delete/GetSchedule` on `schedule/default/k3s-gitops-lab-lease`
    only;
  - `iam:PassRole` on `k3s-gitops-lab-autostop`, only to `scheduler.amazonaws.com`. That
    role can do nothing but stop project-tagged instances (#62).
- GitHub environment **`lab`**: deployment branch policy `main` only, no secrets or
  variables. The role ARN is in the workflow; it isn't a secret.
- `.github/workflows/lab.yml`:
  - `workflow_dispatch` with `action` (start, stop, extend) and `lease_minutes` (180, 60,
    120, 240) inputs;
  - `run-name: lab <action>`, so the run list shows what each run did;
  - `permissions: {}` at workflow level; the job gets `contents: read` and
    `id-token: write`;
  - `concurrency: lab`, never cancelled, so a stop can't interrupt a start halfway;
  - actions pinned by commit; zizmor 1.30.1: no findings.
- `scripts/lab.sh`: CI mode (above); `say` and `die` also write the summary.
- README: the button under "Daily use", the role in the OIDC table.

## Verification
Before the merge (the workflow can only run from `main`):

| Check | Result |
|---|---|
| `terraform plan` (bootstrap), saved and applied | 2 to add (the role, its policy), 0 to change, 0 to destroy |
| IAM policy simulator, **allowed** | start and stop the tagged node, DescribeInstances, create/delete the lease schedule, PassRole autostop to Scheduler |
| IAM policy simulator, **denied** (`implicitDeny`) | start an instance tagged for another project, or untagged; stop with `Stack=bootstrap`; Terminate, ModifyInstanceAttribute, RunInstances; delete or update the nightly schedule; PassRole the node role to EC2; read the DuckDNS token; read Terraform state |
| `lab` environment | branch policy `main` (type branch), 0 secrets |
| `lab.sh status` on the laptop | unchanged |
| `GITHUB_ACTIONS=true lab.sh status` | refused (`only start|stop|extend`), written to the summary |
| zizmor 1.30.1 on `lab.yml` | no findings |

After the merge (recorded with Phase 4's close):
- the button stops the node, then starts it, reading the summary;
- a run from a branch other than `main` is refused by the environment;
- a press from the GitHub mobile app (by the user).

## Gotchas
- **A `workflow_dispatch` workflow appears in the Actions tab only once it is on the
  default branch.** It can't be tried from its own PR.
- **`AWS_PROFILE` must stay unset in CI.** `lab.sh` used to default it to `personal`. On
  a runner that profile doesn't exist, and the AWS CLI refuses a profile it can't find,
  even with valid OIDC credentials in the environment (not tried; that's why CI mode
  skips it).
- **A start from the button doesn't check K3s.** The runner isn't on the tailnet (the
  push deploy's tailnet access, #39, is scoped to its own job). The public `/health` is
  the check, after DuckDNS points at the new IP.
- **The lease is shared with `make`.** Both write the same schedule, so the last start or
  extend wins, whichever side ran it.

## Further reading
- [GitHub: manually running a workflow (workflow_dispatch)](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [GitHub: OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub: deployment environments (branch policies)](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
- [IAM policy simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
