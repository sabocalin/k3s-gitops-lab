# 14 · Ansible: swap and K3s over Tailscale SSH

> Issue: #14 (1.7) · Phase 1

## What
`ansible/` configures the node after Terraform creates it: a 1 GB swap file, then K3s
`v1.36.4+k3s1` installed from the checksum-verified release binary, with a config file
whose API-certificate names come from the node's Tailscale identity, and secrets
encryption on. The laptop reaches the node over **Tailscale SSH**; public 22 stays closed.
This task also moved the node to `eu-central-1b` and gave the platform one subnet per zone.

## Why
Terraform creates machines; Ansible converges what runs on them, and reports honestly
whether it changed anything. Idempotency (a second run changes nothing) is what makes the
playbook safe to re-run and useful to detect drift.

Alternatives considered:
- **K3s install script (`curl -sfL https://get.k3s.io | sh`)** — convenient, but runs
  whatever the URL serves and hides the steps. The role does what the script does,
  visibly: checksum-verified binary, config file, systemd unit.
- **k3s-ansible collection** — full-featured multi-node tooling; more than one node needs,
  and less to learn from.
- **Everything in user_data** — runs once at first boot; no way to re-apply a config
  change without replacing the instance.

## How it works
### Admin path (laptop → node)
```
ansible / ssh ──ProxyCommand: tsu nc %h %p──▶ userspace tailscaled (LaunchAgent, no root)
            ──WireGuard──▶ k3s-node: Tailscale SSH (identity-based, no keys) ─▶ ubuntu + sudo
```
- **Userspace tailscaled** (`--tun=userspace-networking`, run as the user by a LaunchAgent):
  no admin rights, no system VPN, no route changes, so it cannot interfere with the
  employer VPN. `tsu` is the CLI pointed at its socket. The laptop joined as
  `admin-laptop` with `--shields-up` (accepts no inbound tailnet connections).
- **Tailscale policy SSH rule**: `autogroup:admin` → `tag:k3s` as `ubuntu`/`root`, check mode
  off (`accept`), so unattended runs are not interrupted by browser re-authentication.
- **`~/.ssh/config`** `Host k3s-node`: `ProxyCommand tsu nc %h %p`, `PubkeyAuthentication no`,
  a separate known_hosts file.

### Ansible, isolated from the machine's work setup
- **`ansible/requirements.txt`** pins `ansible-core==2.21.4`; `ansible/run.sh` runs it with
  `uv run --no-project`, so the system's ansible-core 2.13 (EOL) is untouched.
- The shell exports employer password-helper variables (`ANSIBLE_*_PASSWORD_FILE`) whose
  helper refuses to run without a terminal. The node needs no passwords, so `run.sh`
  removes them for this repo's runs only.
- `ansible.cfg` is read from the current directory (`run.sh` changes into `ansible/`).

### The roles
- **swap**: `fallocate` (only if missing) → `0600` → `mkswap` (only right after creating) →
  `swapon` (only if not in `/proc/swaps`) → fstab line → `vm.swappiness = 10`.
- **k3s**: assert `aarch64` → read `tailscale status --json` → derive the certificate names →
  `get_url` the binary with `checksum: sha256:<release checksum file>` → config.yaml →
  systemd unit → flush handlers → service enabled/started → wait for `Ready`.
- **Certificate names from facts, not assumptions**: the tailnet IP changed when the node
  was re-registered (100.88.230.89 → 100.117.102.72); reading it at run time kept the
  certificate correct without editing anything.

### Check mode on a fresh host
Under `--check`, "create the swap file" and "install the unit" are only simulated, so the
files do not exist. Tasks that act on them skip in check mode **only** when their
prerequisite would be created (`k3s_simulated`); on an installed host they still run.

## Implementation
`ansible/`: `ansible.cfg`, `inventory.yml`, `site.yml`, `run.sh`, `requirements.txt`,
`roles/swap/{defaults,tasks,handlers}`, `roles/k3s/{defaults,tasks,handlers,templates}`.
Terraform: platform `public_subnets` map (one per zone) with `moved` blocks; instance
`availability_zone` variable (default `eu-central-1b`). Dependabot watches `/ansible`.
Laptop (not in the repo): Homebrew `tailscale`, LaunchAgent
`com.sabocalin.tailscaled-userspace`, `~/.local/bin/tsu`, `Host k3s-node` in `~/.ssh/config`.

## Verification
| Check | Result |
|---|---|
| Laptop routing | default route unchanged (`192.168.1.1 en0`); `ShieldsUp: true` |
| SSH over the tailnet | `hello from ip-10-42-2-197 as ubuntu`, passwordless sudo |
| Public port 22 | timed out (control github.com:22 ok) |
| `--check --diff` | fstab, swappiness, binary, config (SANs from Tailscale), unit; `failed=0` |
| Real runs | run 1 converged K3s (readiness check bug, see Gotchas); runs 2 and 3: **`changed=0`** |
| Node | `Ready`, `v1.36.4+k3s1`, 4 pods Running + 1 Completed |
| API certificate SANs | `k3s-node.taild18d72.ts.net`, `k3s-node`, `100.117.102.72` |
| Swap / secrets encryption | `/swapfile 1024M`, swappiness 10 / `Enabled` |
| Memory | 1060 of 1835 MiB used with only K3s core components |

## Gotchas
- **`command:` strips quotes.** The string form is split shell-style, so
  `jsonpath={...(@.type=="Ready")...}` reached kubectl as `@.type==Ready` and failed on every
  retry while the node was in fact Ready. Use `argv:` for arguments with quotes.
- **Check mode on a fresh host** fails on tasks that need files a previous task only
  simulated creating; guard them explicitly instead of disabling `--check`.
- **`get_url` matches the checksum by the URL's file name** (`url_filename(url)` in the
  module source), so `k3s-arm64` in the checksum file matches even though the binary is
  installed as `/usr/local/bin/k3s`.
- **Zone capacity runs out.** `eu-central-1a` returned `InsufficientInstanceCapacity` for
  t4g.small on every start attempt. Launch-and-terminate probes showed capacity in
  eu-central-1b/1c and all of eu-north-1; the node moved to 1b. `moved` blocks turned the
  single subnet into a per-zone map without destroying it.
- **Removing the old Tailscale device first** let the replacement node take the name
  `k3s-node` again (otherwise `k3s-node-1`); a new registration gets a new tailnet IP.
- **`aws login` sessions last 12 hours**, then need a browser login again.
- **2 GiB is already tight**: 1060 MiB used before any workload. Expect to move to
  t4g.medium (4 GiB, ~$1.54/month at 40 h) before Phase 4 (#47).

## Further reading
- [K3s configuration file](https://docs.k3s.io/installation/configuration#configuration-file)
- [K3s secrets encryption](https://docs.k3s.io/security/secrets-encryption)
- [Ansible command module: argv](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/command_module.html)
- [Tailscale userspace networking](https://tailscale.com/kb/1112/userspace-networking)
- [Tailscale SSH policy rules](https://tailscale.com/kb/1193/tailscale-ssh)
- [Terraform moved blocks](https://developer.hashicorp.com/terraform/language/moved)
