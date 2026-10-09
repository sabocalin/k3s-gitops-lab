#!/bin/sh
# #61: the lab node's lifecycle, run from the laptop (the Makefile calls this).
#
#   start | stop | extend | status   runtime: the instance is kept, only its state changes
#   up | down                        rebuild: create or destroy the instance stack
#   plan                             read-only plan of the instance stack
#   kubeconfig                       fetch the admin kubeconfig (run it yourself: credential)
#
# Every AWS call is refused unless the session belongs to the lab account: on this laptop
# the `default` profile is an employer production account.
#
# #63: also run by the "Start lab" button (.github/workflows/lab.yml), start|stop|extend
# only. There, credentials come from GitHub OIDC (no AWS profile), there is no Tailscale
# (K3s is not checked; the public /health is), and every message also goes to the job
# summary, which is what the mobile app shows.
set -eu

ACCOUNT_ID=466558795290
PROJECT=k3s-gitops-lab
NODE=k3s-node
NODE_FQDN=k3s-node.taild18d72.ts.net
# #36: the node points this at its public IP at every boot (ansible/roles/ddns).
DDNS_NAME=k3s-gitops-lab.duckdns.org
LEASE_NAME=$PROJECT-lease
NIGHTLY_NAME=$PROJECT-nightly-stop
TSU=${TSU:-tsu}
KNOWN_HOSTS=${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_k3s_gitops_lab}
KUBECONFIG_FILE=${KUBECONFIG_FILE:-$HOME/.kube/$PROJECT.yaml}
LEASE_MINUTES=${LEASE_MINUTES:-180}

IN_CI=${GITHUB_ACTIONS:-}
if [ -z "$IN_CI" ]; then
  : "${AWS_PROFILE:=personal}"
  export AWS_PROFILE
fi
: "${AWS_REGION:=eu-central-1}"
export AWS_REGION AWS_PAGER=""

cd "$(dirname "$0")/.."
TF_DIR=terraform/instance

summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; }
say() {
  printf '==> %s\n' "$*"
  summary "- $*"
}
die() {
  printf 'lab: %s\n' "$*" >&2
  summary "- **failed:** $*"
  exit 1
}

# --- guards -------------------------------------------------------------------------

guard_account() {
  account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) ||
    die "no AWS session for profile '$AWS_PROFILE'; run: aws login --profile personal"
  # The other account's id is not printed: it may be the employer's.
  [ "$account" = "$ACCOUNT_ID" ] ||
    die "profile '$AWS_PROFILE' is not the lab account ($ACCOUNT_ID); refusing"
}

guard_tailscale() {
  "$TSU" status >/dev/null 2>&1 ||
    die "Tailscale is not running on this laptop; start it with: $TSU up"
}

guard_lease_minutes() {
  case $LEASE_MINUTES in
    '' | *[!0-9]*) die "LEASE_MINUTES must be a whole number of minutes, got '$LEASE_MINUTES'" ;;
  esac
  [ "$LEASE_MINUTES" -ge 2 ] || die "LEASE_MINUTES must be at least 2"
}

# --- the instance ---------------------------------------------------------------------

# Found by tag, not from Terraform state: start/stop are runtime operations and stay fast
# and independent of Terraform. Terminated instances linger in the API for about an hour,
# so they are filtered out.
find_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Stack,Values=instance" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

instance_id() {
  ids=$(find_instances)
  # shellcheck disable=SC2086 # split the id list on purpose
  set -- $ids
  case $# in
    0) die "there is no lab instance; build one with: make up" ;;
    1) printf '%s\n' "$1" ;;
    *) die "expected one lab instance, found $#: $ids" ;;
  esac
}

state_of() {
  aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

start_instance() {
  say "starting $1"
  if ! err=$(aws ec2 start-instances --instance-ids "$1" 2>&1 >/dev/null); then
    case $err in
      *InsufficientInstanceCapacity*)
        die "AWS has no spare capacity for this instance type in its zone right now.
  Try again in a few minutes. To move zones instead (this replaces the instance), change
  availability_zone's default in $TF_DIR/variables.tf and run: make up" ;;
      *) die "$err" ;;
    esac
  fi
  aws ec2 wait instance-running --instance-ids "$1"
}

show_address() {
  ip=$(aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  if [ "$ip" = None ]; then
    say "no public IP (the instance is not running)"
  else
    say "public IP $ip, hostname $(printf %s "$ip" | tr . -).sslip.io (both change on every start)"
    show_dns "$ip"
  fi
}

# #36: what DuckDNS's own nameserver answers (no resolver cache in between).
ddns_ip() { dig +short +time=3 +tries=1 "$DDNS_NAME" @ns1.duckdns.org 2>/dev/null | head -n 1; }
ddns_points_at() { [ "$(ddns_ip)" = "$1" ]; }
show_dns() { # <public ip>
  current=$(ddns_ip)
  if [ "$current" = "$1" ]; then
    say "dns: $DDNS_NAME -> $current (current)"
  else
    say "dns: $DDNS_NAME -> ${current:-nothing} (STALE: the node updates it at boot)"
  fi
}

# --- the lease ------------------------------------------------------------------------

# Format a Unix time; macOS date takes -r <seconds>, GNU date takes -d @<seconds>.
fmt_epoch() { # <seconds> <format> [-u]
  if date -r 0 >/dev/null 2>&1; then
    date ${3:+"$3"} -r "$1" "+$2"
  else
    date ${3:+"$3"} -d "@$1" "+$2"
  fi
}

# A one-off EventBridge Scheduler schedule that stops the node LEASE_MINUTES from now and
# deletes itself afterwards. Same target and role as the nightly stop (#62), so it can
# stop project-tagged instances and nothing else. Creating it again moves the time.
set_lease() { # <instance id>
  end=$(($(date +%s) + LEASE_MINUTES * 60))
  at=$(fmt_epoch "$end" %Y-%m-%dT%H:%M:%S -u)
  local_end=$(fmt_epoch "$end" '%Y-%m-%d %H:%M %Z')
  role="arn:aws:iam::$ACCOUNT_ID:role/$PROJECT-autostop"
  target=$(printf '{"Arn":"arn:aws:scheduler:::aws-sdk:ec2:stopInstances","RoleArn":"%s","Input":"{\\"InstanceIds\\":[\\"%s\\"]}","RetryPolicy":{"MaximumRetryAttempts":3,"MaximumEventAgeInSeconds":3600}}' "$role" "$1")
  if aws scheduler get-schedule --name "$LEASE_NAME" >/dev/null 2>&1; then
    verb=update-schedule
  else
    verb=create-schedule
  fi
  aws scheduler "$verb" --name "$LEASE_NAME" \
    --description "Session lease (#61): stops the node at $local_end" \
    --schedule-expression "at($at)" --schedule-expression-timezone UTC \
    --flexible-time-window Mode=OFF --action-after-completion DELETE \
    --target "$target" >/dev/null
  if [ -n "$IN_CI" ]; then
    say "lease: the node stops at $local_end (run this workflow again: extend for more time, stop when done)"
  else
    say "lease: the node stops at $local_end (make extend for more time, make stop when done)"
  fi
}

delete_lease() {
  if aws scheduler get-schedule --name "$LEASE_NAME" >/dev/null 2>&1; then
    aws scheduler delete-schedule --name "$LEASE_NAME"
    say "lease removed"
  fi
}

# --- the node over Tailscale ----------------------------------------------------------

tailnet_has_node() {
  "$TSU" status --json |
    jq -e --arg n "$NODE_FQDN." '[(.Peer // {})[] | select(.DNSName == $n)] | length > 0' \
      >/dev/null
}

node_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$NODE" "$@"; }

# Poll <command...> every 10 s, <tries> times.
wait_for() { # <tries> <what> <command...>
  tries=$1 what=$2
  shift 2
  say "waiting for $what (up to $((tries * 10 / 60)) min)"
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt "$tries" ] || return 1
    sleep 10
  done
}

wait_k3s() {
  wait_for 30 "K3s on $NODE over Tailscale" node_ssh sudo k3s kubectl get --raw=/readyz ||
    die "K3s is not ready after 5 min; check: ssh $NODE sudo systemctl status k3s"
  say "K3s is ready: kubectl --context $PROJECT get nodes"
}

# --- terraform ------------------------------------------------------------------------

tf() { terraform -chdir="$TF_DIR" "$@"; }

confirm() {
  printf '%s Only "yes" is accepted: ' "$1"
  read -r answer || answer=
  [ "$answer" = yes ]
}

# Plan to a file, show it, ask, then apply exactly that saved plan. Returns 0 when there
# was nothing to change. Terraform refuses a saved plan whose state changed meanwhile.
plan_and_apply() { # <plan file> <question> [plan flags...]
  plan=$1 question=$2
  shift 2
  tf init -input=false >/dev/null
  rc=0
  tf plan -input=false -detailed-exitcode -out="$plan" "$@" || rc=$?
  case $rc in
    0) rm -f "$TF_DIR/$plan"; say "no changes"; return 0 ;;
    2) ;;
    *) rm -f "$TF_DIR/$plan"; die "terraform plan failed" ;;
  esac
  if ! confirm "$question"; then
    rm -f "$TF_DIR/$plan"
    die "not applied"
  fi
  tf apply -input=false "$plan"
  rm -f "$TF_DIR/$plan"
}

# --- commands ---------------------------------------------------------------------------

cmd_start() {
  guard_account
  guard_lease_minutes
  id=$(instance_id)
  start_instance "$id"
  set_lease "$id"
  show_address "$id"
  if [ -z "$IN_CI" ]; then
    guard_tailscale
    wait_k3s
  fi
  wait_dns "$id"
}

wait_dns() { # <instance id>
  ip=$(aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  if wait_for 12 "$DDNS_NAME to point at $ip" ddns_points_at "$ip"; then
    say "dns: $DDNS_NAME -> $ip"
  else
    say "dns: $DDNS_NAME still -> $(ddns_ip); check: ssh $NODE systemctl status duckdns-update"
    return 0
  fi
  # K3s answering is not the app answering: Traefik restarts after a boot too. Resolve to
  # the new IP explicitly, so the laptop's DNS cache cannot hide or fake the result.
  if wait_for 12 "http://$DDNS_NAME/health" \
    curl -sf --max-time 5 --resolve "$DDNS_NAME:80:$ip" "http://$DDNS_NAME/health"; then
    say "app: http://$DDNS_NAME/health answers"
  else
    say "app: http://$DDNS_NAME/health not answering yet; check Traefik and the lab-api pods"
  fi
}

cmd_stop() {
  guard_account
  id=$(instance_id)
  say "stopping $id"
  aws ec2 stop-instances --instance-ids "$id" >/dev/null
  delete_lease
  aws ec2 wait instance-stopped --instance-ids "$id"
  say "stopped: only the disk is billed now (about \$0.04 a day)"
}

cmd_extend() {
  guard_account
  guard_lease_minutes
  id=$(instance_id)
  state=$(state_of "$id")
  [ "$state" = running ] || die "the node is $state; make start sets a new lease"
  set_lease "$id"
}

cmd_status() {
  guard_account
  ids=$(find_instances)
  if [ -z "$ids" ]; then
    say "node: none (make up builds one)"
  else
    id=$(instance_id)
    say "node: $(aws ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,Placement.AvailabilityZone]' \
      --output text | tr '\t' ' ')"
    show_address "$id"
  fi
  if lease=$(aws scheduler get-schedule --name "$LEASE_NAME" --query Description --output text 2>/dev/null); then
    say "lease: $lease"
  else
    say "lease: none"
  fi
  if nightly=$(aws scheduler get-schedule --name "$NIGHTLY_NAME" \
    --query '[State,ScheduleExpression,ScheduleExpressionTimezone]' --output text 2>/dev/null); then
    say "nightly stop: $(printf %s "$nightly" | tr '\t' ' ')"
  else
    say "nightly stop: none"
  fi
  if "$TSU" status >/dev/null 2>&1; then
    online=$("$TSU" status --json | jq -r --arg n "$NODE_FQDN." \
      '[(.Peer // {})[] | select(.DNSName == $n) | .Online] | if length == 0 then "not registered" elif .[0] then "online" else "offline" end')
    say "tailnet: $NODE $online"
  else
    say "tailnet: Tailscale is not running on this laptop"
  fi
}

cmd_plan() {
  guard_account
  tf init -input=false >/dev/null
  tf plan -input=false
}

cmd_up() {
  guard_account
  guard_lease_minutes
  guard_tailscale
  fresh=false
  if [ -z "$(find_instances)" ]; then
    fresh=true
    ! tailnet_has_node ||
      die "an old '$NODE' device is still in the tailnet; remove it at
  https://login.tailscale.com/admin/machines first, or the new node joins as $NODE-1"
  fi
  plan_and_apply up.tfplan "Apply this plan?"
  id=$(instance_id)
  [ "$(state_of "$id")" = running ] || start_instance "$id"
  if [ "$fresh" = true ]; then
    # A new node has a new SSH host key; forget the old one (this project's file only).
    ssh-keygen -R "$NODE_FQDN" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  fi
  wait_for 60 "$NODE to join the tailnet and accept SSH" node_ssh true ||
    die "$NODE did not come up on the tailnet in 10 min; check its console output in the EC2 console"
  say "waiting for first-boot setup (cloud-init) to finish"
  # Exit 2 means done with recoverable warnings (on this VPC: the IPv6 metadata address is
  # unreachable, so cloud-init falls back to IPv4); 1 means it failed.
  rc=0
  node_ssh cloud-init status --wait >/dev/null || rc=$?
  case $rc in
    0) ;;
    2) say "cloud-init done, with recoverable warnings (ssh $NODE cloud-init status --long)" ;;
    *) say "warning: cloud-init failed (exit $rc); see: ssh $NODE cloud-init status --long" ;;
  esac
  say "configuring the node with Ansible"
  ansible/run.sh ansible-playbook site.yml
  # The ArgoCD bootstrap (#40) joins here.
  set_lease "$id"
  show_address "$id"
  if [ "$fresh" = true ]; then
    say "new cluster, new admin credential: run make kubeconfig, then kcreload in your shell"
  fi
}

cmd_down() {
  guard_account
  plan_and_apply down.tfplan "Destroy the node and its disk?" -destroy
  delete_lease
  # The node's Tailscale device outlives the instance, and it keeps the name k3s-node
  # even when logged out (a logout only expires its key). Only deleting it frees the name.
  if ! "$TSU" status >/dev/null 2>&1 || tailnet_has_node; then
    say "next: remove the old '$NODE' device at https://login.tailscale.com/admin/machines"
    say "(make up refuses to build while it is there: the new node would join as $NODE-1)"
  fi
}

# The admin kubeconfig is a cluster-admin credential. Run this yourself; nothing is printed.
cmd_kubeconfig() {
  umask 077
  tmp="$KUBECONFIG_FILE.tmp"
  node_ssh sudo cat /etc/rancher/k3s/k3s.yaml |
    sed -e "s#https://127.0.0.1:6443#https://$NODE_FQDN:6443#" \
      -e "s/: default\$/: $PROJECT/" >"$tmp"
  grep -q "server: https://$NODE_FQDN:6443" "$tmp" ||
    { rm -f "$tmp"; die "could not fetch the kubeconfig from $NODE"; }
  kubectl --kubeconfig "$tmp" config set "clusters.$PROJECT.proxy-url" socks5://localhost:1055 >/dev/null
  kubectl --kubeconfig "$tmp" config unset current-context >/dev/null
  mv "$tmp" "$KUBECONFIG_FILE"
  say "wrote $KUBECONFIG_FILE (mode 600); run kcreload in your shell"
}

if [ -n "$IN_CI" ]; then
  case ${1:-} in
    start | stop | extend) cmd_"$1" ;;
    *) die "in GitHub Actions only start|stop|extend are allowed" ;;
  esac
else
  case ${1:-} in
    start | stop | extend | status | plan | up | down | kubeconfig) cmd_"$1" ;;
    *) die "usage: $0 start|stop|extend|status|plan|up|down|kubeconfig" ;;
  esac
fi
