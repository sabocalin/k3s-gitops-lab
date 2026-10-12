# #138: the lab's dashboards, as code, in the same folder as the alert (#49).
#
# The JSON files are the source, in Grafana's own dashboard format: change one in the UI,
# then Export -> Export as JSON (with "Export for sharing externally" OFF, so the data
# source uids stay) and replace the file. An edit made only in the UI is overwritten on the
# next apply. scripts/check-dashboards.sh runs every query in them against Grafana Cloud.
#
# Queries use the stack's built-in data sources by uid: grafanacloud-prom (where Alloy
# writes metrics, #48) and grafanacloud-logs (Loki).
resource "grafana_dashboard" "lab" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  folder      = grafana_folder.lab.uid
  config_json = file("${path.module}/dashboards/${each.value}")
}
