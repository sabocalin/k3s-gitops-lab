#!/bin/sh
# Run Ansible for this repo with the pinned ansible-core (requirements.txt), isolated from
# any system-wide Ansible. The node needs no passwords (Tailscale SSH + passwordless sudo),
# so the employer password-helper variables some shells export are removed for these runs
# only; this releases no password and changes nothing outside this command.
set -eu
cd "$(dirname "$0")"
exec env -u ANSIBLE_CONNECTION_PASSWORD_FILE -u ANSIBLE_BECOME_PASSWORD_FILE \
  uv run --quiet --no-project --with-requirements requirements.txt -- "$@"
