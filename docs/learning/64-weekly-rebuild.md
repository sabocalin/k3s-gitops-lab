# 64 · Weekly rebuild from git (and the rebuild-from-zero runbook, #52)

> Issue: #64 (5.7), covers #52's drill · PRs: #124 (build), #125 (first-run fixes), this PR (results) · Phase 5

## What
A scheduled workflow, `rebuild.yml`, runs every Sunday at 03:17 UTC and on demand. It
**destroys the node and builds a new one from git**, deploys the app, checks the public
HTTPS endpoint, and stops the node. Nobody logs in. The new node **restores its identity**
from SSM at first boot and **configures itself** from the repository:
- the identity is the K3s CAs and service-account keys, the Tailscale node state and the
  SSH host keys;
- configuration is Ansible run locally, then the Argo CD bootstrap.

## Why
A manual fix on the node (an edited file, a `kubectl` patch) is invisible until the node
dies, and then the platform can't be rebuilt. Destroying it every week makes git the only
place a change can survive. It also keeps the rebuild path tested, so #52's "rebuild from
zero" is a button, not a weekend.

Before this, a rebuild had three side effects that broke everything that trusted the old
node, every week:
- **a new cluster CA**, which broke the push deploy (`k8s/ci/cluster-ca.crt`) and every
  kubeconfig;
- **a new Tailscale device**, `k3s-node-1`, which broke every name that points at
  `k3s-node`;
- **new SSH host keys**, which made the laptop refuse to connect ("REMOTE HOST
  IDENTIFICATION HAS CHANGED").

Alternatives considered:
- **Ansible over Tailscale from CI**, as the issue says. It needs `tag:ci` to reach port
  22, which the tailnet policy forbids on purpose, with tests (#39). Letting the node
  configure itself (`ansible-pull` style) keeps CI at port 6443 only.
- **Refresh the CA in git after each rebuild** (a bot PR with the new
  `cluster-ca.crt`): one more moving part every week, and laptop kubeconfigs still break.
- **Delete the old Tailscale device through the API before enrolling**: needs a
  Tailscale credential with `devices:core` write; restoring the device's own state needs
  nothing new.
- **Keep the EBS volume across rebuilds**: the opposite of the point. State would survive,
  and so would manual fixes.

## How it works
```
rebuild.yml (environment production, apply role)
  rebuild:  terraform destroy ─▶ terraform apply ─▶ wait until Traefik answers on the new IP
            first boot (cloud-init, user_data.sh.tftpl):
              AWS CLI ─▶ restore 16 identity files from /k3s-gitops-lab/node-identity/*
              ─▶ Tailscale starts with the restored state: same device, same 100.x IP
              ─▶ git clone main ─▶ scripts/node-bootstrap.sh:
                   ansible-core (pinned) in a venv, site.yml locally: swap, K3s, DuckDNS
                   kubectl apply: Argo CD (server-side), k8s/namespaces/*, argocd-apps
              ─▶ Argo CD: cert-manager, issuers, ESO, monitoring, upgrade plans, gitops
  deploy:   deploy-push.yml (workflow_call, wait 900 s): waits for the deployer's RBAC,
            applies namespace push, waits for DNS + the new Let's Encrypt certificate
  finish:   public HTTPS /health = 200 (curl verifies the certificate) ─▶ lab.sh stop
            (always, even after a failure) ─▶ total time in the job summary
```
- **Why the identity makes the rebuild invisible.** The cluster CA is the same, so the API
  server's new certificate is signed by the CA that `k8s/ci/cluster-ca.crt` and the
  laptop's kubeconfig already trust. The admin client certificate in that kubeconfig is
  signed by the restored client CA, so it still authenticates. The service-account key
  is the same, so tokens issued before stay valid. The Tailscale state carries the
  machine and node keys, so the tailnet sees the same device.
- **Why it is restored before the services start.** K3s uses CA files it finds in
  `server/tls` on its first start; tailscaled uses the state file it finds on its first
  start. Both are written before the packages are installed.
- **What doesn't survive, on purpose:** the cluster's objects (Argo CD recreates them from
  git), the certificate (cert-manager issues a new one), and the public IP (DuckDNS
  follows at boot).

## Implementation
- `scripts/save-node-identity.sh`: run once from the laptop with the node up. 16 files
  become SecureStrings (AWS-managed key, $0) under `/k3s-gitops-lab/node-identity<path>`,
  through a pipe, never displayed. Re-run after a deliberate rotation.
- `terraform/instance/user_data.sh.tftpl`:
  - the AWS CLI first;
  - the restore, all-or-nothing, keyed on `server-ca.key` existing. It reads exact values
    (JSON output; `--output text` adds a newline), sets the same file modes as the
    originals, rebuilds the SSH public keys from the private ones, and restarts `ssh`;
  - Tailscale, falling back to OAuth enrolment if the restored state doesn't log in;
  - `git clone --depth 1 main`, then `bash scripts/node-bootstrap.sh`.
  - Template variables `identity_prefix` (a platform output) and `repo_url`.
- `scripts/node-bootstrap.sh`: `python3-venv`, `pip install -r ansible/requirements.txt`,
  `ansible-playbook site.yml -e ansible_connection=local`, wait for `/readyz`, then the
  Argo CD bootstrap.
- `terraform/platform/iam_node.tf`: `ssm:GetParameter` on `node-identity/*`, read only.
- `.github/workflows/rebuild.yml`: `schedule` (Sunday 03:17 UTC, off the hour) and
  `workflow_dispatch`. Three jobs: `rebuild` (`scripts/rebuild-node.sh`), `deploy`
  (`uses: $/.github/workflows/deploy-push.yml`, the self-repository form), and `finish`
  (`if: always()`). `concurrency: lab`, shared with the Start lab button.
- `scripts/deploy-push.sh`: `DEPLOY_WAIT_SECONDS`, default 0. A normal deploy stays
  strict; the rebuild waits for RBAC and the certificate.
- `scripts/lab.sh`: `make up` and `make down` know about the saved identity (no "remove
  the old device" step, no `ssh-keygen -R`, no Ansible run on a fresh node). The health
  check is now **HTTPS**: over HTTP, the redirect (308) passed `curl -f` without the app
  ever answering.

## Verification
**First run (37948377782): failed, and taught three things** (fixed in #125):
1. **The apply role couldn't launch the instance.** `RunInstances` was denied on the
   Canonical AMI: those images carry the owner alias `amazon`, and for an aliased image
   the `ec2:Owner` condition key is the alias, not the account id. Every earlier launch
   ran from the laptop as admin; this was CI's first. The role now allows
   `[099720109477, "amazon"]` (simulator: both allowed, any other owner denied).
2. **`node-bootstrap.sh` was committed without its executable bit**, so first boot
   stopped at `Permission denied`. The mode is fixed, and user_data runs it through `bash`.
3. **Argo CD's controller was OOMKilled 6 times** at 384 Mi. On a fresh cluster it syncs
   every app at once, and adopting existing objects (#43) had never needed that. New limits:
   controller 1 Gi, repo-server 640 Mi.

The destroyed node was rebuilt from the laptop with the same code, and its bootstrap was
run by hand after fix 2. That build proved the identity restore:
- Tailscale reconnected as the **same device with the same IP** (100.101.255.61);
- the laptop's **existing kubeconfig** worked against the new cluster at once;
- the SSH host key was unchanged (no warning).

**Second run (37951163016): success, fully automated.** This is also #52's drill.

| UTC | Step | Took |
|---|---|---|
| 15:21:54 | run starts | |
| 15:22:50 | `terraform destroy` (instance + nightly schedule) | 56 s |
| 15:23:12 | `terraform apply`, new instance running | 22 s |
| 15:31:50 | first boot until Traefik answers on the new IP | 8 min 38 s |
| 15:32:25 | deploy: API and the deployer's RBAC ready, logged in via GitHub OIDC | 35 s |
| 15:33:55 | namespace push rolled out (3/3 on the pinned digest) | 1 min 30 s |
| 15:45:28 | public HTTPS `/health` 200: DNS and the new Let's Encrypt certificate | 11 min 33 s |
| 15:45:41 | finish: HTTPS 200 again; **total 23 min 45 s** | |
| 15:46:34 | node stopped | |

Negative control: the first run is one. A run that can't build the node fails red; the
`finish` job still ran its stop step, and the run reported failure instead of passing
quietly.

## Runbook: rebuild from zero (#52)
1. **Normal:** Actions → rebuild → Run workflow (or wait for Sunday). About 24 minutes;
   the node is stopped at the end. `make start` to use it.
2. **From the laptop:** `make up` (plan, confirm, apply). The node configures itself;
   then run the deploy-push workflow once for namespace push.
3. **If the identity is lost** (deleted from SSM, or a new project): the node makes a new
   one. Then delete the old `k3s-node` device in the Tailscale admin first, refresh
   `k8s/ci/cluster-ca.crt` and the kubeconfig (`make kubeconfig`), and run
   `scripts/save-node-identity.sh` again.
4. **Where to look:** EC2 console output or `/var/log/cloud-init-output.log` (lines
   `K3SLAB:`); `kubectl -n argocd get applications`; the run's job summary.

## Gotchas
- **`ec2:Owner` is the alias for aliased AMIs** (`amazon`, `aws-marketplace`), not the
  account id. A policy written against the id passes every laptop test and fails the first
  real CI launch.
- **New files lose their executable bit** unless set before `git add`. user_data runs
  scripts through `bash`, so it doesn't depend on it.
- **A fresh cluster needs more controller memory than a running one.** Size Argo CD for the
  first sync, not for steady state.
- **The certificate is the slowest step** (11.5 minutes). On a fresh node every image is
  pulled at once and Argo CD syncs the apps one after another; cert-manager's images
  arrived about 9 minutes after boot. The certificate itself took seconds once the
  ClusterIssuers existed.
- **A rebuild starts from an empty `push` namespace**: the push path deploys it, not
  Argo CD. That's why the workflow calls deploy-push and `make up` says so.
- **The node runs the repository's `main` at first boot**: whatever is merged is what the
  next node runs. That is the point, and why `main` is protected (#6).

## Further reading
- [K3s: custom CA certificates](https://docs.k3s.io/cli/certificate#using-custom-ca-certificates)
- [Tailscale: state directory and reusing node identity](https://tailscale.com/kb/1278/tailscaled)
- [IAM: ec2:Owner condition key](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html#amazonec2-policy-keys)
- [GitHub: reusing workflows (workflow_call)](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
