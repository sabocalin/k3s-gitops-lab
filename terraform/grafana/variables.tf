variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  description = "Region of the SSM parameters and the state bucket."
  type        = string
  default     = "eu-central-1"
}

variable "grafana_url" {
  description = "The Grafana Cloud stack (#48). Not secret."
  type        = string
  default     = "https://grayhare2068.grafana.net"
}

variable "prometheus_datasource_uid" {
  description = "The stack's built-in Prometheus (Mimir) data source, where Alloy writes (#48)."
  type        = string
  default     = "grafanacloud-prom"
}
