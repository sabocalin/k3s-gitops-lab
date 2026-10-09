#!/bin/bash
# #64: run ON THE NODE, as root, by the first-boot script (terraform/instance/
# user_data.sh.tftpl) from a fresh clone of this repository. Turns an Ubuntu instance into
# the lab node without anyone logging in:
#
#   1. Ansible, the pinned ansible-core (ansible/requirements.txt) in a venv, run locally
#      against this host: swap, K3s (the pinned version, OIDC authentication config),
#      DuckDNS. The same playbook the laptop runs over SSH (make up on an existing node).
#   2. The Argo CD bootstrap, the two manual steps of #43, plus the admin-owned namespaces:
#        k8s/platform/argocd       (server-side: the ApplicationSet CRD is too big for
#                                   client-side apply, #40)
#        k8s/namespaces/{push,gitops}  (namespaces, guardrails, the push deployer's RBAC)
#        k8s/platform/argocd-apps  (root and every Application; Argo CD does the rest)
#
# The app in namespace push is NOT deployed here: that is the push path's job (CI,
# deploy-push.yml), which the rebuild workflow runs next.
set -euo pipefail

log() { echo "K3SLAB: $*"; }
repo=$(cd "$(dirname "$0")/.." && pwd)

# --- 1. Ansible --------------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
python3 -m venv /opt/ansible-venv
/opt/ansible-venv/bin/pip install --quiet --disable-pip-version-check -r "$repo/ansible/requirements.txt"
log "ansible $(/opt/ansible-venv/bin/ansible --version | head -1) installed"

# From ansible/, so ansible.cfg (inventory, roles path) applies. Local connection: the
# inventory's host is this machine.
(cd "$repo/ansible" &&
  /opt/ansible-venv/bin/ansible-playbook site.yml --limit k3s-node -e ansible_connection=local)
log "ansible done"

# --- 2. Argo CD bootstrap ----------------------------------------------------------------
k() { /usr/local/bin/k3s kubectl "$@"; }

for _ in $(seq 1 60); do
  k get --raw=/readyz >/dev/null 2>&1 && break
  sleep 5
done
k get --raw=/readyz >/dev/null
log "K3s API ready: $(k version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"

k apply --server-side --force-conflicts -k "$repo/k8s/platform/argocd" >/dev/null
k wait --for condition=established --timeout=180s \
  crd/applications.argoproj.io crd/appprojects.argoproj.io crd/applicationsets.argoproj.io
log "argo cd installed"

k apply -k "$repo/k8s/namespaces/push" >/dev/null
k apply -k "$repo/k8s/namespaces/gitops" >/dev/null
log "namespaces push and gitops (guardrails, deployer RBAC) applied"

k apply -k "$repo/k8s/platform/argocd-apps" >/dev/null
log "root application applied; argo cd takes over from here"
