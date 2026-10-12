output "alert_rule_folder_url" {
  description = "Where the alert rule appears in Grafana."
  value       = "${var.grafana_url}/alerting/list?search=folder:${urlencode(grafana_folder.lab.title)}"
}

output "dashboard_urls" {
  description = "The dashboards (#138), by file name."
  value       = { for file, d in grafana_dashboard.lab : trimsuffix(file, ".json") => d.url }
}
