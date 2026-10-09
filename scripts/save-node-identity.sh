#!/bin/sh
# #64: copy the node's identity into SSM Parameter Store, so a rebuilt node can restore it
# at first boot and look the same to everything that trusts it:
#   K3s CAs + service-account keys  -> same cluster CA (k8s/ci/cluster-ca.crt, kubeconfigs)
#   Tailscale state                 -> same tailnet device, name and IP (no k3s-node-1)
#   SSH host keys                   -> same host key (no "REMOTE HOST IDENTIFICATION HAS CHANGED")
#
# Each file becomes a SecureString (AWS-managed key, $0) named
# /k3s-gitops-lab/node-identity<path on the node>. Contents go from the node straight
# into SSM through a pipe; nothing is printed or written on the laptop.
#
# Run from the laptop with the node up, after a deliberate change of any of these (for
# example a CA rotation):   AWS_PROFILE=personal scripts/save-node-identity.sh
set -eu

: "${AWS_PROFILE:=personal}"
export AWS_PROFILE AWS_REGION=eu-central-1 AWS_PAGER=""

account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = 466558795290 ] || { echo "not the lab account; refusing" >&2; exit 1; }

tls=/var/lib/rancher/k3s/server/tls
for f in \
  "$tls/server-ca.crt" "$tls/server-ca.key" \
  "$tls/client-ca.crt" "$tls/client-ca.key" \
  "$tls/request-header-ca.crt" "$tls/request-header-ca.key" \
  "$tls/service.key" "$tls/service.current.key" \
  "$tls/etcd/peer-ca.crt" "$tls/etcd/peer-ca.key" \
  "$tls/etcd/server-ca.crt" "$tls/etcd/server-ca.key" \
  /var/lib/tailscale/tailscaled.state \
  /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_rsa_key; do
  ssh -n k3s-node "sudo cat $f" |
    aws ssm put-parameter --type SecureString --overwrite --value file:///dev/stdin \
      --name "/k3s-gitops-lab/node-identity$f" >/dev/null
  echo "ok $f"
done
