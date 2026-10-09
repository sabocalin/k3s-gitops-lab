# 49 · Alert: lab-api readiness failing for more than 2 minutes, by email

> Issue: #49 (5.2) · Phase 5

## What
A Grafana-managed alert rule, defined in Terraform (`terraform/grafana`). When a lab-api pod
in `push` or `gitops` stays not-ready for 2 minutes, Grafana Cloud sends an email, and
sends another when the pod recovers. The rule reads `kube_pod_status_ready` from
kube-state-metrics, which Alloy ships to Grafana Cloud (#48).

## Why
Readiness is what users feel. A pod can be alive (`/health` 200) and still be out of the
Service (`/ready` 503: draining, a dependency down, stuck startup), and with three
replicas nobody notices until the second one goes. Nothing watched for this before: the
lab had no alerting at all.

Alternatives considered:
- **Click the alert together in the Grafana UI**: quicker once, but not reviewable,
  not rebuildable, and silently different after the next edit. The rest of the project is
  code.
- **Mimir/Prometheus-style rules + Alertmanager (`mimirtool`)**: the standard Prometheus
  path, but Grafana Cloud's hosted Alertmanager has no built-in mail server, so it would
  need SMTP credentials. Grafana-managed alerting sends email itself.
- **Alert on the `/ready` endpoint with a synthetic probe (Grafana Synthetic Monitoring)**:
  it tests from outside, but the free tier is small. `gitops` has no public URL, and the
  probe would see the Service, which hides a single not-ready pod behind the healthy ones.
- **`up == 0` or the Deployment's available replicas**: `up` says the scrape failed, not
  that the pod is out of traffic. "Available < desired" also fires during every rolling
  update.

## How it works
```
kubelet: readiness probe /ready fails ─▶ pod condition Ready=False ─▶ Endpoints drop the pod
kube-state-metrics: kube_pod_status_ready{condition="false"} = 1
Alloy: scrape every 30 s ─▶ Grafana Cloud Prometheus
Grafana rule (every 30 s): max by (namespace, pod) (...{namespace=~"push|gitops"}) > 0
  Normal ─(condition true)─▶ Pending ─(still true after `for: 2m`)─▶ Alerting
  ─▶ notification_settings: contact point "k3s-gitops-lab email" (group_wait 10 s) ─▶ email
  ─(condition false)─▶ Normal ─▶ "resolved" email on the group's next flush (53 s here)
```
- **`for: 2m`.** The condition must hold for two consecutive minutes of evaluations before
  the alert fires. A rolling update makes each new pod not-ready for its startup delay
  (about 5 s), which never reaches `for`.
- **One alert per pod.** `max by (namespace, pod)` gives one series per pod, so each pod
  is its own alert instance and a second failing pod sends its own email.
  `group_by: [alertname, namespace, pod]` keeps them as separate notifications.
- **No data is OK.** If kube-state-metrics or Alloy is down, there's no series at all.
  That's a different problem ("monitoring is down"), not "a pod is not ready", so
  `no_data_state = "OK"` keeps this rule quiet.
- **Simplified routing.** `notification_settings` sends this rule straight to the contact
  point, so the stack's notification-policy tree (Grafana Cloud's own defaults) is left
  alone.
- **The recipient isn't in git.** The repo is public, so the email address is the SSM
  parameter `/k3s-gitops-lab/grafana-cloud/alert-email` (a plain String). Terraform reads
  it with a data source.
- **The token isn't in state.** The Grafana provider reads `GRAFANA_AUTH` from the
  environment. `scripts/tf-grafana.sh` fills it from SSM for the one command, and nothing
  prints it, so neither a variable nor a data source puts it into the state.

## Implementation
- `terraform/grafana/` (new stack, state `grafana/terraform.tfstate` in the same
  bucket):
  - `versions.tf`: `grafana/grafana` **4.47.0** exactly (4.48 and 4.49 were a day old),
    `hashicorp/aws` 6.66.0 like the other stacks (6.68.0 was 2 days old). Hashes for
    `linux_amd64` and `darwin_arm64` in the lock file.
  - `alerting.tf`:
    - the email data source;
    - a folder `k3s-gitops-lab alerts` inside the stack's `GrafanaCloud` folder (see
      Gotchas);
    - an email contact point, with resolve messages on;
    - rule group `lab-api` (interval 30 s), one rule: query A on `grafanacloud-prom`
      (instant), threshold C `> 0`, `for = "2m"`, `no_data_state = "OK"`,
      `exec_err_state = "Error"`, labels `severity=warning`, an annotation with the
      `kubectl describe` to run, `notification_settings` (group_wait 10 s, repeat 4 h).
- `scripts/tf-grafana.sh`: guards the account, reads the service-account token from SSM
  into `GRAFANA_AUTH` for one `terraform` process, and runs it in `terraform/grafana`.
- Applied from saved plans, from the laptop (like bootstrap): Grafana changes stay a
  laptop apply, with no CI token.

## Verification
| Check | Result |
|---|---|
| `make lint` (fmt, validate, tflint, trivy) with the new stack | all Terraform checks passed |
| Apply (second plan, after the folder fix) | 2 to add (folder, rule group); the contact point already existed from the first attempt |
| Plan again | no changes (exit 0) |
| Rule in Grafana | `health=ok`, 6 instances (one per lab-api pod), all Normal |

**Done when**, the deliberate failure: one `gitops` pod drained with SIGUSR1 (#29), which
makes `/ready` return 503 while `/health` stays 200, so it's not restarted.

| Time (UTC) | Event |
|---|---|
| 14:20:51 | drained `lab-api-59f5d75b88-m824g` |
| 14:21:04 | pod `Ready=False` (readiness probe), 0 restarts |
| 14:22:00 | alert **Pending** (the next scrape and evaluation saw it) |
| 14:24:00 | alert **Alerting** (2 minutes later) |
| 14:24:11 | email sent by the contact point: 1.4 s, no error |
| 14:24:59 | undrained |
| 14:25:12 | pod Ready again |
| 14:26:07 | alert back to **Normal** |
| 14:27:00 | "resolved" email sent: no error |

From pod failure to email: 3 min 07 s (the 2-minute hold, plus up to 30 s scrape, 30 s
evaluation and 10 s group wait).

Grafana reports the send as successful; arrival in the inbox is for the user to confirm.

Negative control: the other 5 pods' instances stayed Normal throughout. Only the
drained pod alerted, and only after the 2-minute hold (Pending for exactly 2 minutes
first, not Alerting on the first failed evaluation).

## Gotchas
- **A top-level folder created by the service account is unreadable by that same account
  (403 `folders:read`).** In this stack the account's folder permissions are per folder:
  read/write on `GrafanaCloud`, create at the root. The first apply created
  `k3s-gitops-lab`, then failed reading it back. It was removed from the Terraform state;
  the empty folder is left for the user to delete in the UI (the account can't). A folder
  **nested** in `GrafanaCloud` inherits that folder's permissions, so Terraform can manage
  it.
- **The "resolved" email isn't instant either**: the rule went Normal at 14:26:07 and the
  resolved notification left at 14:27:00. Grafana's alertmanager sends it on its next
  flush for that group, not on the evaluation itself.
- **A Grafana-managed rule needs its query's data source UID**: `grafanacloud-prom` here,
  the stack's built-in Prometheus. Rules in other stacks would need their own UID.

## Further reading
- [Grafana: alert rule evaluation, pending period (`for`)](https://grafana.com/docs/grafana/latest/alerting/fundamentals/alert-rule-evaluation/)
- [Grafana: configure notifications from the alert rule (simplified routing)](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/create-grafana-managed-rule/)
- [Terraform provider grafana: grafana_rule_group](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/rule_group)
- [kube-state-metrics: pod metrics](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md)
