#!/bin/sh
# #138: run every query of every dashboard in terraform/grafana/dashboards against Grafana
# Cloud and fail if any returns no data (or an error) in the window.
#
#   scripts/check-dashboards.sh                      the last 7 days
#   scripts/check-dashboards.sh <start> <end>        RFC 3339, e.g. 2026-10-11T10:05:00Z
#
# A panel that renders "No data" looks the same whether the cluster was idle or the query
# is wrong (a typo in a metric or label name). Run it over a window when the node was up:
# every query must find something then.
#
# Dashboard variables are replaced by what "All" or an empty box would give: $namespace by
# .+, $search by nothing; $__rate_interval by 10m (twice the 300 s step, so rate() always
# has two samples). The token comes from SSM, as in tf-grafana.sh, and is never printed:
# it reaches curl through stdin (-H @-), not its arguments.
set -eu
: "${AWS_PROFILE:=personal}"
export AWS_PROFILE AWS_REGION=eu-central-1 AWS_PAGER=""
cd "$(dirname "$0")/.."

grafana=https://grayhare2068.grafana.net
start=${1:-$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)}
end=${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = 466558795290 ] || { echo "not the lab account; refusing" >&2; exit 1; }
token=$(aws ssm get-parameter --name /k3s-gitops-lab/grafana-cloud/terraform-token \
  --with-decryption --query Parameter.Value --output text)

# <datasource uid> <query>: prints the number of series (metrics) or streams (logs).
count() {
  case $1 in
    grafanacloud-prom) path=api/v1/query_range ;;
    grafanacloud-logs) path=loki/api/v1/query_range ;;
    *) echo "unknown datasource $1" >&2; return 1 ;;
  esac
  printf 'Authorization: Bearer %s\n' "$token" | curl -sS -G -H @- \
    "$grafana/api/datasources/proxy/uid/$1/$path" \
    --data-urlencode "query=$2" --data-urlencode "start=$start" \
    --data-urlencode "end=$end" --data-urlencode step=300 --data-urlencode limit=1 |
    jq -r 'if .status == "success" then (.data.result | length)
           else "error: \(.error // .message // .)" end'
}

echo "window: $start .. $end"
failed=0
tab=$(printf '\t')
for file in terraform/grafana/dashboards/*.json; do
  board=$(jq -r .title "$file")
  queries=$(jq -r '.panels[] | select(.targets) | .title as $t
    | .targets[] | [$t, .datasource.uid, .expr] | @tsv' "$file")
  while IFS=$tab read -r title ds expr; do
    q=$(printf '%s' "$expr" | sed -e 's/\$namespace/.+/g' -e 's/\$search//g' \
      -e 's/\$__rate_interval/10m/g')
    n=$(count "$ds" "$q")
    case $n in
      '' | 0 | error*) printf 'FAIL  %s / %s: %s\n' "$board" "$title" "${n:-empty reply}"; failed=$((failed + 1)) ;;
      *) printf 'ok    %s / %s: %s\n' "$board" "$title" "$n" ;;
    esac
  done <<EOF
$queries
EOF
done
[ "$failed" -eq 0 ] || { echo "$failed queries returned no data" >&2; exit 1; }
echo "every query returned data"
