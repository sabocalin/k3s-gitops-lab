output "alert_rule_folder_url" {
  description = "Where the alert rule appears in Grafana."
  value       = "${var.grafana_url}/alerting/list?search=folder:${grafana_folder.lab.title}"
}
