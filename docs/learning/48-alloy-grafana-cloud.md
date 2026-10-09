# 48 · Metrics and logs to Grafana Cloud (free tier) via Alloy

> Issue: #48 (5.1) · Phase 5

## What
**Grafana Alloy** runs in namespace `monitoring` and sends two kinds of data to a Grafana
Cloud free stack (`grayhare2068`):
- **metrics:** lab-api's `/metrics` in both delivery namespaces, plus kube-state-metrics,
  to Grafana Cloud's Prometheus (Mimir);
- **logs:** every pod's logs, to Loki.

**kube-state-metrics** turns pod and Deployment state into metrics (readiness, restarts),
which the alert in #49 needs.

## Why
Until now, "is it working" meant `kubectl` from the laptop, while the node was up. The
chaos drills (#50) need graphs and logs that outlive the pods and the node. Grafana
Cloud's free tier (10k active series, 50 GB of logs, 14 days of retention) costs $0, and
nothing heavy runs on the 4 GiB node: no Prometheus, Loki or Grafana there.

Alternatives considered:
- **Self-hosted Prometheus + Loki + Grafana in the cluster**: free in money, but about
  1 GiB of memory on this node, and the data dies with the node (a weekly rebuild, #64).
- **Grafana Agent**: Alloy's predecessor, end of life.
- **Promtail for logs**: deprecated in favour of Alloy, and it reads `/var/log/pods` through
  a hostPath, which breaks Pod Security "restricted".
- **The upstream Helm chart for Alloy**: the project renders everything with Kustomize.
  The chart's output for this setup is four objects, written out here.

## How it works
```
lab-api pods (push, gitops) ──/metrics──▶ ┐
kube-state-metrics (monitoring) ──────────▶ │ Alloy: prometheus.scrape (30 s)
                                            │   + label cluster="k3s-gitops-lab"
                                            ├──▶ remote_write ──▶ prometheus-prod-65 (Mimir)
Kubernetes API: pods/log (every pod) ─────▶ │ loki.source.kubernetes
                                            └──▶ loki.write ───▶ logs-prod-012 (Loki)
token: SSM ─(ESO, #54)─▶ Secret grafana-cloud ─▶ env GRAFANA_CLOUD_TOKEN (basic-auth password)
```
- **Discovery.** `discovery.kubernetes` watches pods through the API. For metrics, it lists
  pods labelled `app.kubernetes.io/name=lab-api` in `push` and `gitops`, and keeps the
  container port named `http`, giving one target per pod. For logs, it lists every pod.
- **Logs through the API, not the disk.** `loki.source.kubernetes` streams `pods/log` from
  the API server, the same thing `kubectl logs -f` does. No hostPath, so `monitoring` stays
  "restricted". The cost is some load on the API server; fine for one node.
- **NetworkPolicy.** The app namespaces deny all ingress by default (#33). A new policy in
  `k8s/namespace-base` lets pods labelled `app.kubernetes.io/name=alloy` in namespace
  `monitoring` (both conditions, the AND form) reach the `http` port.
- **The token.** An ExternalSecret (#54) creates Secret `grafana-cloud`, and Alloy reads it
  as an env var through `sys.env`. The usernames and URLs aren't secret and sit in the
  config. The token's access policy has two scopes, `metrics:write` and `logs:write`; it
  can't read anything back.
- **Staying in the free tier.** kube-state-metrics watches two resources only (`pods`,
  `deployments`), and an allowlist keeps six metrics. Alloy's own and the node's metrics
  aren't sent. Measured: **826 active series**.

## Implementation
- `k8s/platform/monitoring/`:
  - `namespace.yaml`: `monitoring`, Pod Security "restricted".
  - `externalsecret-grafana-cloud.yaml`: SSM `/k3s-gitops-lab/grafana-cloud/alloy-token`
    becomes Secret `grafana-cloud`, key `token`.
  - `alloy.yaml`: ServiceAccount, a ClusterRole (read pods and namespaces, `get pods/log`),
    its binding, and a Deployment:
    - 1 replica with `strategy: Recreate`, since two writers would send every log line twice;
    - `runAsUser: 473`: **the image sets no USER, so it would run as root**;
    - read-only root filesystem, every writable path an emptyDir;
    - `--disable-reporting` (no usage statistics to Grafana);
    - readiness on `/-/ready`; resources 96/320 Mi.
  - `alloy-config.alloy`: the pipeline above, formatted with the image's own `alloy fmt`.
    A `configMapGenerator` adds a content hash to the ConfigMap name, so a config change
    rolls the pod.
  - `vendor/kube-state-metrics-v2.20.0/`: upstream `examples/standard` at the tag's
    commit, unmodified, with sha256s in `vendor/SHA256SUMS`. A patch adds
    `--resources=pods,deployments`, the metric allowlist and resources (24/96 Mi).
  - Images pinned by digest. kube-state-metrics is signed by the Kubernetes release
    process (keyless, `krel-trust@k8s-releng-prod`). **Alloy's image has no cosign
    signature** (checked), so it's pinned by digest only, like redis in #40.
- `k8s/namespace-base/networkpolicy.yaml`: `allow-alloy-to-lab-api-metrics`, applied to
  `push` and `gitops` by an admin (`k8s/namespaces/*` isn't under Argo CD yet, #43).
- `k8s/platform/argocd-apps/application-monitoring.yaml`, with
  `SkipDryRunOnMissingResource` and a retry: the ExternalSecret is an instance of ESO's
  CRD. The `platform` AppProject gains namespace `monitoring` and kind `ExternalSecret`.

## Verification
Pre-merge, the Application ran from the branch in a temporary project (`test-48`), as in
#54. The NetworkPolicy was applied to both namespaces after a server dry run.

| Check | Result |
|---|---|
| Application `monitoring` | Synced/Healthy in 25 s; ExternalSecret `SecretSynced`; Alloy and kube-state-metrics 1/1 |
| Alloy components (its API, `/api/v0/web/components`) | 11/11 healthy; no warn/error lines in its log |
| Scrape targets | 7 up: 3 lab-api pods in `push`, 3 in `gitops`, kube-state-metrics |
| Sent | metrics: 2358 samples, 0 failed, 0 retried; logs: 11,851 lines, 0 dropped |
| **Done when, metrics in Grafana Cloud** (Grafana's API, `grafanacloud-prom`) | `up{job="lab-api"}`: 3 in `push`, 3 in `gitops`; `rate(http_requests_total[5m])` in both; `kube_pod_status_ready` for every namespace |
| **Done when, logs in Grafana Cloud** (`grafanacloud-logs`) | lines in the last 10 min from argocd, external-secrets, gitops, kube-system, monitoring and push; newest `push` lab-api line: `GET /ready HTTP/1.1 200 OK` |
| Free-tier budget | 826 active series (of 10,000) |
| **Memory** (the issue asks) | Alloy **191 Mi**, kube-state-metrics 20 Mi |

Negative control: with `allow-alloy-to-lab-api-metrics` deleted from `gitops`, its 3
targets went **down** (`dial tcp …:8000: connect`), while the 3 in `push` stayed up.
Default-deny applies to Alloy too. Re-applied from git: 6/6 up.

The Grafana API was queried with the service-account token for #49. It went from SSM
straight into the request header through a pipe and was never printed.

## Gotchas
- **The Alloy image runs as root unless told otherwise.** It sets no `USER`. With only
  `runAsNonRoot: true` (which "restricted" requires), the kubelet would refuse to start
  the container ("image will run as root"); `runAsUser: 473` gives it a real non-root
  identity.
- **`honor_labels = true` for kube-state-metrics.** Its metrics carry `namespace` and
  `pod` labels describing the object, not the exporter. Without it, the scrape would
  rename them to `exported_namespace` and so on.
- **Alloy's memory is mostly the log tailers and the WAL**: 191 Mi with about 25 pods.
  The limit is 320 Mi. More pods, more streams; watch it in #50.
- **`alloy fmt` uses tabs** and blank lines between blocks; the committed file is its
  output.

## Further reading
- [Grafana Alloy: components reference](https://grafana.com/docs/alloy/latest/reference/components/)
- [loki.source.kubernetes](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes/)
- [kube-state-metrics: metric allow/deny lists](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/developer/cli-arguments.md)
- [Grafana Cloud free tier limits](https://grafana.com/pricing/)
