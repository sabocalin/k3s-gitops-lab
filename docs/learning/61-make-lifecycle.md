# 61 · `make start / stop / extend / status / up / down`

> Issue: #61 (1.11) · Phase 1

## What
One command per lifecycle step, run from the laptop: a `Makefile` in front of
`scripts/lab.sh`. `start`/`stop` change the instance's state, `up`/`down` create and
destroy the instance stack, and every `make start` sets a **session lease**: a one-off
schedule that stops the node 3 hours later unless you extend it.

## Why
Stop-when-idle is the cost model, so starting and stopping has to be the easy path, not
a set of `aws` commands to remember. The lease caps a forgotten session at 3 hours at any
time of day; the nightly stop (#62) only helps after 23:00.

Alternatives considered:
- **Shell aliases** — not in the repo, not reviewable, gone on a new laptop.
- **Terraform for start/stop** (`aws_ec2_instance_state`) — a plan/apply for a runtime
  toggle, and the state file fights the lease and the nightly stop.
- **GitHub Actions buttons** — that is #63 (phone start), and it needs the OIDC roles (#16).
- **CloudWatch idle alarm as the lease** — K3s idles at a few % CPU, so "idle" is a guess;
  a fixed deadline you can extend is predictable.

## How it works
```
make <target>  ─▶ Makefile: AWS_PROFILE=personal (override), AWS_REGION=eu-central-1
                   └─▶ scripts/lab.sh <target>
                        ├─ guard: sts get-caller-identity == 466558795290, else refuse
                        ├─ instance: found by tags Project + Stack=instance (not Terraform state)
                        └─ node: reached over Tailscale SSH (Host k3s-node, #14)
```
- **The lease** is an EventBridge Scheduler schedule `k3s-gitops-lab-lease`:
  `at(<UTC time>)`, `ActionAfterCompletion=DELETE` (it removes itself after firing), and
  the same universal target and role as the nightly stop (`ec2:stopInstances`, role
  `k3s-gitops-lab-autostop`, limited to project-tagged instances). `make extend` updates
  it in place; `make stop` deletes it. It is runtime state, created by the CLI, not by
  Terraform: it exists only while a session does.
- **`make up`** plans to a file, shows it, asks for a literal `yes`, and applies **that
  saved plan** (Terraform refuses a saved plan if the state changed meanwhile). Then it
  waits for the node on the tailnet, waits for cloud-init, runs Ansible, and sets a lease.
  The ArgoCD bootstrap joins here with #40.
- **`make down`** does the same with a destroy plan, removes the lease, and then says
  whether the old Tailscale device still has to be removed (see Gotchas).
- **Fail closed:** `make up` refuses to build when an old `k3s-node` device is still in the
  tailnet (the new node would join as `k3s-node-1` and the certificate names would break).

## Implementation
- `Makefile`: `override AWS_PROFILE := personal`, so even `make start AWS_PROFILE=x` runs
  as personal; `LEASE_MINUTES ?= 180`.
- `scripts/lab.sh` (POSIX sh, shellcheck-clean): guards (account, Tailscale, lease
  length), instance lookup by tag, capacity-error message on start, lease upsert/delete,
  wait loops, saved-plan apply, kubeconfig fetch.
- `README.md`: "Daily use" table; running model mentions the lease.

## Verification
| Check | Result |
|---|---|
| **Negative: script with `AWS_PROFILE=default`** | `lab: no AWS session for profile 'default'` (no employer login was made for this test) |
| **Negative: account mismatch** (copy of the script expecting `000000000000`) | `lab: profile 'personal' is not the lab account (000000000000); refusing` |
| **Negative: Terraform** `-var account_id=000000000000` | `Error: AWS account ID not allowed: 466558795290` |
| `make status AWS_PROFILE=default` | still ran as personal: the `override` wins |
| `make extend LEASE_MINUTES=abc` | refused |
| `make start` | 32 s to K3s ready; lease `at(2026-09-30T17:09:13)` UTC, `DELETE` after completion, target = this instance, role = autostop |
| kubectl from the laptop | `k3s-node Ready` |
| `make extend LEASE_MINUTES=3` | lease updated in place to `at(2026-09-30T14:12:37)` |
| **The lease fires** | `stopping` by 14:12:56Z, `stopped` 14:13:12Z; the schedule deleted itself |
| **CloudTrail: who stopped it** | 14:12:44Z `assumed-role/k3s-gitops-lab-autostop` (the lease); the next stop, 14:14:06Z, `user/saboxcalin-admin` (`make stop`) |
| `make stop` | stopped, `lease removed`; `make status` shows `lease: none`, tailnet `offline` |
| **Negative: `make extend` while stopped** | `lab: the node is stopped; make start sets a new lease` |
| `make down` with `yes` (you ran it) | `Resources: 0 added, 0 changed, 2 destroyed.`, `lease removed` |
| **Negative: `make up` with the old device still in the tailnet** | `lab: an old 'k3s-node' device is still in the tailnet ... the new node joins as k3s-node-1`; nothing was planned or created |
| **`make up` from nothing** (you ran it, after removing the old device) | new instance `i-0c689738af5e6f2db`, lease set, IP printed |
| Rebuilt node | tailnet name `k3s-node` (not `-1`), new tailnet IP `100.76.138.124`; `Ready v1.36.4+k3s1`; API certificate names include `k3s-node.taild18d72.ts.net` and the new IP; swap 1024M |
| Nightly stop after the rebuild | recreated, target = the new instance id |
| **`make up` again** | `No changes` (no prompt), Ansible `changed=0`: idempotent |
| `make down` without `yes` | destroy plan shown (`aws_instance.node`, `aws_scheduler_schedule.nightly_stop`: 2 to destroy), then `not applied`; the node kept running |

## Gotchas
- **`tailscale logout` does not remove a device.** The first version of `make down` logged
  the node out before destroying it. Afterwards the device was still listed:
  `Expired: true`, key expiry moved into the past, name still `k3s-node`. A logout only
  expires the node key; the device, and its name, stay until deleted in the admin console
  or through the API. `make down` now says so, and `make up` refuses to build until it is gone.
- **cloud-init ends "degraded" on every boot** (`cloud-init status` exits 2, `errors: []`):
  it tries the IPv6 metadata address `fd00:ec2::254` first, and this VPC has no IPv6. The
  script reports exit 2 as recoverable and only warns on 1.
- **Scheduler `at()` has no time zone in the string**; it is read in
  `ScheduleExpressionTimezone`. The script always writes UTC and puts local time in the
  description.
- **macOS and GNU `date` differ** (`-r <seconds>` vs `-d @<seconds>`); `fmt_epoch` handles both.
- **`ConnectTimeout` covers the SSH banner** even through a `ProxyCommand`: an offline node
  fails in 10 s, which keeps the wait loops honest.
- **The kubeconfig is a credential**: `make kubeconfig` is for you to run; it prints nothing
  from the file.

## Further reading
- [EventBridge Scheduler: one-time schedules](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html#one-time)
- [ActionAfterCompletion](https://docs.aws.amazon.com/scheduler/latest/APIReference/API_CreateSchedule.html#scheduler-CreateSchedule-request-ActionAfterCompletion)
- [Terraform saved plans](https://developer.hashicorp.com/terraform/cli/commands/plan#out-filename)
- [tailscale logout](https://tailscale.com/kb/1080/cli#logout)
- [GNU make: override directive](https://www.gnu.org/software/make/manual/html_node/Override-Directive.html)
