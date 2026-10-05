#!/bin/sh
# #28: zero-downtime check. Copy into a curl pod in the target namespace and run:
#   kubectl -n push run rollout-probe --image=curlimages/curl@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13 \
#     --restart=Never --command -- sleep 3600 \
#     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"rollout-probe","image":"curlimages/curl@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13","command":["sleep","3600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
#   (the namespace enforces Pod Security "restricted" since #31)
#   kubectl -n push cp k8s/tests/request-loop.sh rollout-probe:/tmp/loop.sh
#   kubectl -n push exec rollout-probe -- sh /tmp/loop.sh 75 > results.txt &   # then: rollout restart
#   awk '{c[$1]++} END {for (k in c) print k, c[k]}' results.txt
# Uses the short Service name (same namespace). See docs/learning/28-rollout.md for why not the FQDN.

# Runs inside the curl pod (namespace push): request the Service "lab-api" for $1 seconds, one line per request:
# "<http code> <pod that answered>" (code 000 = connection failed or timed out).
end=$(( $(date +%s) + $1 ))
while [ "$(date +%s)" -lt "$end" ]; do
  body=$(curl -s --max-time 2 -w ' %{http_code}' http://lab-api/)
  code=${body##* }
  pod=$(printf '%s' "$body" | sed -n 's/.*"pod":"\([^"]*\)".*/\1/p')
  echo "$code ${pod:--}"
  sleep 0.05
done
