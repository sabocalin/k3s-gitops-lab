# 138 · Grafana dashboards as code: lab-api and platform

> Issue: #138 (5.8) · PR: see issue · Phase 5

## What
Two dashboards in Grafana Cloud, defined in `terraform/grafana` next to the alert (#49),
in the folder `GrafanaCloud / k3s-gitops-lab`:

| Dashboard | Shows | URL |
|---|---|---|
| **lab-api** | the app in `push` and `gitops`: pods ready, requests, 5xx share, latency p50/p95/p99, replicas, CPU and memory per pod against their limits, restarts, pods scraped, logs | `/d/k3s-lab-api` |
| **Platform** | every namespace on the node: running and not-running pods, Deployments short of replicas, restarts, scrape health, log volume, error-like lines, searchable logs | `/d/k3s-lab-platform` |

Both have a **Namespace** drop-down and a **Log search** box, link to each other, and open
on the last 24 hours. `scripts/check-dashboards.sh` runs every query in them against
Grafana Cloud and fails if one finds nothing.

## Why
Explore and the Drilldown apps answer one question at a time, and you have to know the
metric and label names first. A dashboard is the answer to "is the lab healthy?" on one
bookmarked page. Before this, it was only a set of queries in a learning note (#48).

Alternatives considered:
- **Build them in the UI only.** Fastest, but nothing reviews or versions them. A dashboard
  that someone edits into uselessness can't be rolled back, and nothing records why a
  panel exists. As code, a panel change is a PR like any other.
- **Grafana Cloud's Kubernetes Monitoring app.** Ready-made, but it expects Grafana's own
  collector (the k8s-monitoring Helm chart) and its metric set: node exporter, cAdvisor,
  kubelet. This cluster sends six kube-state-metrics series and the app's metrics on
  purpose (free tier, #48), so the app would be mostly empty.
- **Dashboards in HCL** (`jsonencode` of a Terraform map). Reviewable, but nobody can paste
  a UI export into it. Grafana's own JSON lets a change round-trip: edit in the UI, export,
  replace the file.
- **Grafonnet / Grizzly / Foundation SDK.** Generators that are worth it for dozens of
  dashboards with shared panels. For two, they add a toolchain.
- **File provisioning.** That's Grafana reading dashboards from disk at startup, and there's
  no disk on a Grafana Cloud stack. Terraform through the HTTP API is the managed equivalent.

## How it works
```
terraform/grafana/dashboards/*.json ──fileset()──▶ grafana_dashboard.lab[<file>]
   scripts/tf-grafana.sh (token from SSM) ──POST /api/dashboards/db──▶ Grafana Cloud
                                                                       folder k3s-gitops-lab
panel query ──▶ data source grafanacloud-prom (Mimir: what Alloy writes, #48)
            └─▶ data source grafanacloud-logs (Loki)
```
- **The JSON is the source.** It's Grafana's dashboard model: `uid`, `title`, `templating`
  (variables), `panels` (each with a `gridPos` on a 24-column grid, a `datasource` and
  `targets`). Terraform sends it as is. The `uid` is fixed (`k3s-lab-api`,
  `k3s-lab-platform`), so the URLs never change and Terraform updates the same dashboard
  instead of creating another.
- **Data sources by uid.** Every query names `grafanacloud-prom` or `grafanacloud-logs`,
  the stack's built-in data sources. A name could change; these uids are what Grafana
  Cloud creates for every stack.
- **Variables.** `$namespace` is a query variable,
  `label_values(up{cluster="k3s-gitops-lab", job="lab-api"}, namespace)` for lab-api. Grafana
  asks Prometheus for the label's values **within the dashboard's time range**, and refreshes
  them when the range changes (`refresh: 2`). With "All" selected, Grafana substitutes a
  regular expression of every value (`(gitops|push)`), which is why queries use
  `namespace=~"$namespace"`. `$search` is a text box. The log panels add
  `|~ "(?i)$search"`, so an empty box matches every line.
- **`$__rate_interval`.** `rate()` needs at least two samples inside its window. Grafana
  computes this variable from the data source's scrape-interval setting and the panel's
  resolution: at least 4× the scrape interval, more when zoomed out. A fixed `[1m]` would draw gaps when zoomed out.
- **Thresholds that mean something.** The red lines on CPU (250 millicores) and memory
  (128 MiB) are the container limits from #30: above the CPU limit the pod is throttled,
  above the memory limit it's OOM-killed. "Pods ready" turns red below 3, the HPA minimum
  (#34).

### What each signal comes from
| Panel | Metric | Source |
|---|---|---|
| requests, status, latency | `http_requests_total`, `http_request_duration_seconds` | the app's `/metrics` (#19) |
| CPU, memory | `process_cpu_seconds_total`, `process_resident_memory_bytes` | the Python client's process collector, same `/metrics` |
| pods ready, phases, restarts, replicas | `kube_pod_*`, `kube_deployment_*` | kube-state-metrics' six allowlisted metrics (#48) |
| scrape health | `up` | written by Alloy for every scrape it attempts |
| logs, log volume | Loki streams `{cluster, namespace, pod, container, app}` | Alloy's `loki.source.kubernetes` (#48) |

## Implementation
- `terraform/grafana/dashboards/lab-api.json`, `platform.json`: the dashboards.
- `terraform/grafana/dashboards.tf`: one `grafana_dashboard` per JSON file
  (`for_each = fileset(...)`), all in `grafana_folder.lab`. A new file is a new dashboard.
- `terraform/grafana/alerting.tf`: the folder is renamed from "k3s-gitops-lab alerts" to
  "k3s-gitops-lab", now that it holds both. The uid stays, so the rename is an in-place
  update and the alert rule doesn't move.
- `terraform/grafana/outputs.tf`: `dashboard_urls`.
- `scripts/check-dashboards.sh`: extracts every panel query with `jq`, replaces the
  variables (`$namespace` → `.+`, `$search` → nothing, `$__rate_interval` → `10m`), and runs
  each one through Grafana's data source proxy (`/api/datasources/proxy/uid/<uid>/...`).
  That's the same backend path the panels use. Any query with 0 series, 0 log streams or
  an error fails. Default window: the last 7 days.

## Verification
| Check | Result |
|---|---|
| Plan | 2 to add (the dashboards), 1 to change (folder title, in place), 0 to destroy |
| Apply, then plan again | applied; the second plan found no changes (`-detailed-exitcode` 0) |
| Read back through the API | lab-api: 14 panels; Platform: 11 panels; both in `GrafanaCloud / k3s-gitops-lab`; variables `namespace`, `search` |
| The lab-api variable over 7 days | `["gitops", "push"]` |
| `scripts/check-dashboards.sh`, last 7 days | **28 of 28 queries returned data**, e.g. requests by route: 7 series; memory per pod: 12; Platform's restarts per pod: 33 |
| **Negative control** | with `process_resident_memory_bytes` misspelled and the log selector set to `app="lab-apu"`: `FAIL lab-api / Memory per pod (RSS): 0`, `FAIL lab-api / lab-api logs: 0`, `2 queries returned no data`, exit 1. The file was restored byte for byte (`cmp`) |

## Gotchas
- **"No data" means two different things.** An idle node and a wrong label look the same
  on a panel. That's the reason for the check script, and why it runs over a window when
  the node was up. With the node stopped, widen the time range (top right) to see past
  sessions.
- **The namespace drop-down is empty when the range is.** Label values are looked up within
  the time range: "Last 6 hours" after a stopped weekend lists nothing. The variable
  refreshes on every range change, so widening the range fixes it.
- **Requests include the probes.** The kubelet calls `/ready` every 2 s and `/health` every
  10 s per pod, about 2 requests per second at rest. "Requests by route" separates them.
- **`or vector(0)` and operator precedence.** Without 5xx responses the numerator has no
  series, and `x / y` with a missing `x` is empty, not 0. `(… or vector(0))` fills the gap.
  `or` binds more loosely than `/`, so the parentheses are required: `a or b / c` means
  `a or (b / c)`.
- **RSS isn't the cgroup's working set.** The memory panel reads the process's resident
  memory; the OOM killer and `kubectl top` count the container's working set (cgroup). They
  track each other closely for this single-process image, but they aren't the same number.
- **Exporting from the UI:** use Export → Export as JSON with **"Export for sharing
  externally" off**. With it on, Grafana replaces the data source uids with `${DS_...}`
  placeholders, which only resolve through an import dialog, never through Terraform.
- **The check is laptop-only.** It needs the Grafana token, and the CI roles are explicitly
  denied the project's SSM parameters (#16). The JSON's syntax is still checked by
  `terraform plan`.
- **Logs count as one stream.** The check asks Loki for `limit=1`: for a log panel, "1"
  means "at least one line", not the number of streams.

## Further reading
- [Grafana dashboard JSON model](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/)
- [Terraform provider: grafana_dashboard](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/dashboard)
- [Prometheus template variables: label_values](https://grafana.com/docs/grafana/latest/datasources/prometheus/template-variables/)
- [$__rate_interval](https://grafana.com/docs/grafana/latest/datasources/prometheus/template-variables/#use-__rate_interval)
- [PromQL operator precedence](https://prometheus.io/docs/prometheus/latest/querying/operators/#binary-operator-precedence)
