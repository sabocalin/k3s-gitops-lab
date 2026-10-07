# 36 (part 1) · A fixed hostname for a changing IP: DuckDNS, updated at boot

> Issue: #36 (3.10), part 1 of 2 · Phase 3 · Part 2: cert-manager and Let's Encrypt

## What
The node now has a fixed public name, **`k3s-gitops-lab.duckdns.org`**. Its public IP still
changes on every start, so a systemd unit runs at every boot: it reads the new IP from the
instance metadata service, takes a DuckDNS token from SSM Parameter Store, and updates the
name. `make start` waits until the name points at the new IP and the app answers through it.

## Why
#36 needs a TLS certificate, and a certificate is issued for a **name**. With
`<ip>.sslip.io` (#35) the name changes with every start. That would mean a new certificate
each time, and a hostname that can't be written into git. It's also a Let's Encrypt
problem: `sslip.io` is **not** on the Public Suffix List. Let's Encrypt allows 50
certificates per week per registered domain, so every sslip.io user on the internet shares
those 50. `duckdns.org` **is** on the list, so `k3s-gitops-lab.duckdns.org` gets its own
bucket.

Alternatives considered:
- **deSEC (`dedyn.io`)**: the first choice (non-profit, on the suffix list), but its sign-up
  form had the dynDNS option disabled (October 2026).
- **Per-start `<ip>.sslip.io`**: no account, but the shared rate limit, a new certificate
  per start, and a host that only exists in the live cluster, not in git.
- **Elastic IP**: a fixed IP, but about $3.60/month even while stopped (README "never create").
- **Route 53 hosted zone + an own domain**: $0.50/month for the zone plus a domain;
  also on the "never create" list.
- **Update from the laptop in `make start`**: simpler, but the laptop would need the token,
  and a node started any other way (the "Start lab" button, #63) would keep a stale name.

## How it works
```
boot ─▶ network-online ─▶ duckdns-update.service (oneshot, /usr/local/sbin/duckdns-update)
          1. IMDSv2: PUT /latest/api/token, then GET /latest/meta-data/public-ipv4
          2. aws ssm get-parameter --with-decryption /k3s-gitops-lab/duckdns/token
             (allowed by the node role for exactly this parameter, #12)
          3. https://www.duckdns.org/update?domains=k3s-gitops-lab&token=…&ip=<public ip>
             → "OK" (or "KO": bad token or a name this token doesn't own)
DuckDNS ns1..ns9 answer k3s-gitops-lab.duckdns.org A <ip>, TTL 60 s
```
- **The token never touches disk, argv, or logs.** It goes SSM → a shell variable → curl's
  **stdin** (`curl --config -`, the URL built by `printf`, which is a shell builtin, so no
  process carries it). A token in a curl argument would be readable by any user via `ps`
  while the request runs. The script prints only the IP.
- **TTL 60 s**: resolvers drop the old address within a minute of the update.
- **Retries**: `Restart=on-failure` every 15 s, at most 20 tries in 10 minutes, then the unit
  stays failed and `make start` says so.
- `make status` and `make start` ask DuckDNS's own nameserver (`dig @ns1.duckdns.org`), not
  the laptop's resolver, so a cache can't hide a stale record.

## Implementation
- **SSM parameter** `/k3s-gitops-lab/duckdns/token` (SecureString, `aws/ssm` key), created
  out of band so the value never enters Terraform state or this repo:
  ```sh
  pbpaste | tr -d '\n' | AWS_PROFILE=personal aws ssm put-parameter \
    --region eu-central-1 --type SecureString \
    --name /k3s-gitops-lab/duckdns/token \
    --tags Key=Project,Value=k3s-gitops-lab \
    --value file:///dev/stdin
  pbcopy < /dev/null
  ```
  To rotate: regenerate the token on duckdns.org, rerun with `--overwrite` instead of `--tags`.
- `terraform/platform/iam_node.tf`: a second `ssm:GetParameter` statement for exactly this
  ARN (no wildcard), plus an output with the name. Plan: 2 resources changed in place, 0
  destroyed; re-plan clean after the apply.
- `ansible/roles/ddns` (in `site.yml` after `k3s`):
  - `/usr/local/sbin/duckdns-update` (0750 root): the script above.
  - `duckdns-update.service`: `Type=oneshot` + **`RemainAfterExit=yes`**, so after a run the unit
    stays `active (exited)`. Ansible's `state: started` is then idempotent, and `systemctl
    status` shows the last result. `After=network-online.target snapd.seeded.service` (the
    AWS CLI is a snap). Hardening: `PrivateTmp`, `ProtectSystem=full`,
    `ProtectKernelTunables/Modules`, `ProtectControlGroups`, `RestrictSUIDSGID`.
  - Handlers: daemon-reload, and `restarted` on any change, so a new script runs now and not
    only at the next boot.
- `scripts/lab.sh`: `DDNS_NAME`; `make status` prints `dns: … (current)` or `(STALE…)`.
  `make start` waits (up to 2 min each) for the name to point at the new IP, then for
  `http://<name>/health`. The second check uses `curl --resolve`, so it's the new IP that
  answers.
- `README.md`: diagram, `make start`, cost model and "never create" table mention the name.

## Verification
| Check | Result |
|---|---|
| Before the role (fresh `make start`) | `dns: … -> 209.94.72.136 (STALE…)`, the laptop's IP from sign-up: the STALE check works |
| Ansible `--check --diff` | only the 2 new files; swap and K3s roles unchanged |
| Apply | `duckdns: k3s-gitops-lab.duckdns.org -> 18.184.142.39` (after the fix below) |
| Second run | `changed=0` |
| DNS | DuckDNS's nameserver and Cloudflare (1.1.1.1) both `18.184.142.39`, TTL 60 |
| Through the name, from the laptop | `http://k3s-gitops-lab.duckdns.org/health` → 200 |
| **Negative: a name the token doesn't own** (same script, other subdomain) | `duckdns: update refused: 'KO'`, exit 1; the real record unchanged |
| **Stop/start #1** (the real test: new IP, nothing but the boot unit can fix DNS) | new IP `3.122.252.165`; journal: unit started 8 s after boot, updated 4 s later, first try; `make start` saw the name follow |
| **Stop/start #2**, with the new `make start` waits | `dns: … -> 3.73.158.109`, then `app: http://k3s-gitops-lab.duckdns.org/health answers` |

## Gotchas
- **`NoNewPrivileges=yes` breaks snaps.** The first apply failed: `cannot change profile for
  the next exec call: Operation not permitted`. `/snap/bin/aws` starts through
  `snap-confine`, which is setuid and switches AppArmor profile, and `no_new_privs` forbids
  both. The line was removed (with a comment saying why). The first two failed runs logged
  nothing at all; only the third printed the reason.
- **"K3s is ready" is not "the app answers".** After a boot Traefik restarts too. Right
  after stop/start #1, `/health` timed out while DNS was already correct. Hence the second
  wait in `make start`.
- **DuckDNS answers HTTP 200 for failures too** (body `KO`), so the script checks the body,
  not the status code.
- **The token can update every subdomain on the DuckDNS account** and is visible on
  duckdns.org whenever you're logged in. That account is for this lab only.
- **DuckDNS is a free volunteer service.** If it's down at boot, the name stays stale (the
  unit retries for 10 minutes). The cluster itself is unaffected, and the certificate (part 2)
  stays valid; only new visitors are pointed at the old IP.
- The name is public and ends up in Certificate Transparency logs once a certificate exists.

## Further reading
- [DuckDNS: spec](https://www.duckdns.org/spec.jsp)
- [Public Suffix List](https://publicsuffix.org/) and [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
- [EC2 instance metadata (IMDSv2)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [systemd.exec: NoNewPrivileges](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#NoNewPrivileges=)
