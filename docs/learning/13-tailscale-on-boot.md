# 13 · user_data: install Tailscale and join the tailnet on first boot

> Issue: #13 (1.6) · Phase 1

## What
`terraform/instance/user_data.sh.tftpl` is the instance's first-boot script. It installs
Tailscale from its signed apt repository, installs the AWS CLI, reads the Tailscale OAuth
client secret from SSM (#12), and joins the tailnet as `k3s-node` with tag `tag:k3s` and
Tailscale SSH enabled. From then on the node has a private, stable address
(`k3s-node.taild18d72.ts.net`, `100.88.230.89`) that works while the public IP changes on
every start and ports 22/6443 stay closed to the internet.

## Why
Admin access (SSH, Ansible, kubectl) must not depend on open inbound ports. Tailscale
builds an encrypted WireGuard network between your devices: each side connects **out**
to Tailscale's coordination server, then they talk directly (or via a relay), so the
security group needs no inbound rule for it.

Alternatives considered:
- **SSH on port 22 restricted to your IP** — your home IP changes; the office laptop is
  behind corporate NAT; and it is still an internet-facing port.
- **Bastion host** — a second instance to secure and pay for.
- **AWS Session Manager only** — kept as break-glass (#12), but it does not give a network
  path for kubectl or Ansible without extra port-forwarding plumbing.
- **`curl https://tailscale.com/install.sh | sh`** — runs whatever that URL serves; the apt
  repository verifies package signatures against Tailscale's key.

## How it works
### First boot only
cloud-init runs user_data **once**, on the instance's first boot. Changing the script on an
existing instance would do nothing, so `user_data_replace_on_change = true` makes Terraform
replace the instance whenever the script changes. That matches the weekly-rebuild model:
instances are disposable, the script is the source of truth.

### The secret's path
```
SSM (SecureString) ──aws ssm get-parameter──▶ /run/ts-authkey.XXXXXX  (tmpfs, 0600)
                                                     │  tr -d '\n', then append
                                                     │  ?ephemeral=false&preauthorized=true
                                                     ▼
                     tailscale up --auth-key=file:/run/ts-authkey.XXXXXX
                                                     │  OAuth token → one-off auth key
                                                     ▼
                                     node registered as tag:k3s; file shredded (trap EXIT)
```
- **Only the parameter name** is in user_data (visible via `describe-instance-attribute`).
- **`file:` instead of the value on the command line**: arguments are visible to any
  process via `ps`.
- **`/run` is memory-backed**: the secret never touches the disk.
- **Attributes in the query string**: `ephemeral=false` keeps the node registered while it
  is stopped; `preauthorized=true` skips device approval.

### Why the node survives stop/start
Tailscale saves the node's identity (its key) under `/var/lib/tailscale` on the EBS
volume. After a start, `tailscaled` (a systemd service) reads it and reconnects with the
**same** tailnet IP, no auth key needed. Tagged devices have key expiry disabled, so this
keeps working indefinitely.

### Tailscale's addresses
| Value | Meaning |
|---|---|
| `k3s-node` | short name, from `--hostname` |
| `k3s-node.taild18d72.ts.net` | MagicDNS name; `taild18d72.ts.net` is this tailnet's private domain, resolvable only inside the tailnet |
| `100.88.230.89` | tailnet IPv4 from `100.64.0.0/10` (carrier-grade NAT range, never routed on the internet); stable, tied to the node key |
| `fd7a:115c:a1e0::a629:e65a` | tailnet IPv6 from Tailscale's `fd7a:115c:a1e0::/48` |

## Implementation
- **`user_data.sh.tftpl`**: `set -euo pipefail`, never `set -x` (it would print the
  secret). `K3SLAB:` log markers go to the EC2 console for verification. A guard rejects a
  stored secret that is not a single-line `tskey-client-...` value.
- **`main.tf`**: `user_data = templatefile(...)` with region, parameter name, tag and
  hostname; `user_data_replace_on_change = true`.
- **Tailscale admin**: nothing new (tag and OAuth client from #12).

## Verification
| Check | Result |
|---|---|
| Rendered script | `bash -n` ok; only region, parameter name, tag, hostname templated; 0 `tskey` |
| Boot markers (console) | tailscale 1.102.4 installed → aws-cli 2.35.21 → secret 63 + 35 bytes → IP `100.88.230.89` → `online=True tags=['tag:k3s']` → done |
| Secret in console output | 0 occurrences |
| Secret in live user_data | 0; the parameter name once |
| Admin console | `k3s-node`, `tag:k3s`, Expiry disabled, SSH, Connected |
| Public port 22 | still **timed out** (control: github.com:22 succeeds) |
| **Stop → start** | new public IP; tailnet IP **unchanged** (`100.88.230.89`), Connected again with no re-auth |

**Moved to #14:** "SSH works over the tailnet" needs a Tailscale client on the admin
machine and an SSH rule in the Tailscale policy, both prerequisites of Ansible-over-SSH.

## Gotchas
- **A trailing newline broke authentication (HTTP 401).** `aws ... --output text` ends
  with `\n`. The first version appended `?ephemeral=...` after it, producing
  `secret\n?attrs`. Tailscale trims whitespace only at the *ends* of the file, then splits
  at `?`, so it sent `secret\n` as the secret. The console's byte count gave it away: 99 =
  63 + 1 + 35.
- **How it was found without ever reading the secret:** (1) a shape check run by the owner
  (prefix, length, whitespace) showed the stored value was well-formed; (2) sending the
  stored value to Tailscale's token endpoint from the laptop returned 200 (a fake secret,
  as negative control, returned 401), so the secret was valid and the fault was on the
  node; (3) reading Tailscale 1.102.4's source (`resolveValueFromFile`,
  `parseOptionalAttributes`) ruled out attribute parsing and pointed at the file content.
  The fix was reproduced locally with a fake secret: old logic sent `'...\n'`, new logic
  `'...'`.
- **Tailscale can read Parameter Store itself.** 1.102's CLI resolves `--auth-key` values
  that are SSM ARNs (`resolveValueFromParameterStore`), and has a dedicated
  `--client-secret` flag. Either could remove the AWS CLI snap and the temp file; not
  adopted yet because attributes (`ephemeral`, `preauthorized`) would need another route.
- **user_data changes replace the instance.** Expected and intended here, but it means a
  new instance ID, new public IP and a fresh first boot every time the script changes.

## Further reading
- [Tailscale: OAuth clients as auth keys](https://tailscale.com/kb/1215/oauth-clients)
- [Tailscale on Ubuntu 24.04 (apt repository)](https://tailscale.com/kb/1476/install-ubuntu-2404)
- [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
- [Tailscale IP addresses (100.64.0.0/10)](https://tailscale.com/kb/1033/ip-and-dns-addresses)
- [cloud-init: user data runs on first boot](https://cloudinit.readthedocs.io/en/latest/explanation/format.html)
