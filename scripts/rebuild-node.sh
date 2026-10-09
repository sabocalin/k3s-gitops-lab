#!/bin/sh
# #64: destroy the node and build a new one from git, from CI (rebuild.yml) with the apply
# role. Then wait until the new node answers on its public IP (K3s and Traefik running).
# The node configures itself at first boot (user_data.sh.tftpl, scripts/node-bootstrap.sh);
# the push namespace is deployed by the next job (deploy-push.yml).
#
# Writes timings to $GITHUB_STEP_SUMMARY and the new IP to $GITHUB_OUTPUT (ip=...).
set -eu
cd "$(dirname "$0")/.."
export AWS_PAGER=""

now() { date +%s; }
row() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '| %s | %s |\n' "$1" "$2" >>"$GITHUB_STEP_SUMMARY"; }
mmss() { printf '%d min %02d s' $(($1 / 60)) $(($1 % 60)); }
tf() { terraform -chdir=terraform/instance "$@"; }

[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### Rebuild\n\n| Step | Took |\n|---|---|\n' >>"$GITHUB_STEP_SUMMARY"

tf init -input=false -no-color >/dev/null
t=$(now)
tf destroy -auto-approve -input=false -no-color -lock-timeout=120s
row "terraform destroy" "$(mmss $(($(now) - t)))"

t=$(now)
tf apply -auto-approve -input=false -no-color -lock-timeout=120s
row "terraform apply (new instance running)" "$(mmss $(($(now) - t)))"

ip=$(aws ec2 describe-instances \
  --filters Name=tag:Project,Values=k3s-gitops-lab Name=tag:Stack,Values=instance \
  Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "new node: $ip"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "ip=$ip" >>"$GITHUB_OUTPUT"

# Traefik answering on :80 (any HTTP status, usually 404 or a redirect) means cloud-init
# got far enough for K3s to run. The bootstrap (Argo CD, namespaces) continues; the deploy
# job waits for the deployer's RBAC itself.
t=$(now)
end=$((t + 1200))
until code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip/") && [ "$code" != 000 ]; do
  [ "$(now)" -lt "$end" ] || { echo "rebuild: nothing answers on http://$ip/ after 20 min" >&2; exit 1; }
  sleep 15
done
row "first boot until K3s and Traefik answer" "$(mmss $(($(now) - t)))"
echo "node answers on http://$ip/ ($code)"
