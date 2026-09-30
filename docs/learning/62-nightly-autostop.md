# 62 · Nightly auto-stop (EventBridge Scheduler)

> Issue: #62 (1.12) · Phase 1

## What
Every night at 23:00 Europe/Bucharest, EventBridge Scheduler calls EC2 `StopInstances` on
the node. No Lambda, no code: Scheduler's **universal target** calls the AWS API directly.
It uses a role that can stop project-tagged instances and nothing else.

## Why
The account is on the paid plan with no credits, and a forgotten running instance is the
only realistic way this project's cost grows (public IPv4 + instance hours after
2026-12-31). The budget alert (#2) only *reports* spend; this *prevents* the common case.

Alternatives considered:
- **CPU-idle alarm → stop** — K3s idles at a few % CPU, so any threshold is a guess and
  could stop the node mid-session. A fixed time is predictable.
- **Lambda on a schedule** — code to write, package and patch for a one-line API call.
- **Instance Scheduler (AWS solution)** — a CloudFormation stack with DynamoDB and Lambda;
  far more than one schedule needs.
- **Laptop cron** — only works when the laptop is on.

## How it works
```
EventBridge Scheduler  cron(0 23 * * ? *)  Europe/Bucharest
   └─ assumes k3s-gitops-lab-autostop  (trust: scheduler.amazonaws.com, SourceAccount = this account)
       └─ ec2:StopInstances {"InstanceIds": ["<current node id>"]}
            allowed only if the instance has tag Project=k3s-gitops-lab
```
- **Where each piece lives**: the role is in the **platform** stack (permanent) and is scoped
  by **tag**, so it survives instance rebuilds; the schedule is in the **instance** stack
  because it names the current instance id, which changes on every rebuild.
- **Confused-deputy guard**: the trust policy requires `aws:SourceAccount` to be this
  account, so a scheduler in another account cannot use the role.
- **Timezone-aware cron**: `schedule_expression_timezone` handles daylight saving; 23:00
  stays 23:00 local time all year.
- **Idempotent target**: stopping an already-stopped instance is a no-op.
- **Retries**: up to 3 attempts within an hour if the API call fails.
- **Cost**: $0 (the free tier covers millions of Scheduler invocations a month).

## Implementation
- `terraform/platform/iam_autostop.tf`: role + policy (`ec2:StopInstances` on
  `instance/*` with `aws:ResourceTag/Project = k3s-gitops-lab`); output `autostop_role_arn`.
- `terraform/instance/autostop.tf`: `aws_scheduler_schedule.nightly_stop`, flexible window
  off, universal target `arn:aws:scheduler:::aws-sdk:ec2:stopInstances`.

## Verification
| Check | Result |
|---|---|
| Schedule | `cron(0 23 * * ? *)`, `Europe/Bucharest`, `ENABLED`, input = current instance id |
| Simulator: StopInstances, tag `k3s-gitops-lab` | allowed |
| Simulator: StopInstances, tag `other` | implicitDeny |
| Simulator: TerminateInstances / StartInstances | implicitDeny / implicitDeny |
| **End to end** | node started 13:18; one-off `at(13:21:00 UTC)` schedule with the same role and target stopped it at **13:21:27**; the one-off schedule deleted itself |
| **CloudTrail: who stopped it** | `assumed-role/k3s-gitops-lab-autostop` (the scheduler), not the admin user |

## Gotchas
- **Scheduler schedules cannot carry tags** (schedule groups can), so the default-tags check
  skips them.
- **The simulator needs the tag as a context entry** (`aws:ResourceTag/Project`) to evaluate a
  tag-conditioned policy; without it the condition cannot match.
- **zsh does not word-split `${3:+--flag "$3"}`** the way bash does: the optional argument
  arrived as one word and the simulator rejected it. Pass arguments explicitly.
- **Nightly stop is a safety net, not the plan.** Stop the node yourself after each session;
  23:00 catches the forgotten evening.

## Further reading
- [EventBridge Scheduler universal targets](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-targets-universal.html)
- [Schedule types (cron, at) and time zones](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html)
- [Confused deputy prevention for Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/cross-service-confused-deputy-prevention.html)
- [Controlling access with resource tags](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_tags.html)
