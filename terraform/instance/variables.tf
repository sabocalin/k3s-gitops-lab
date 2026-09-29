variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "instance_type" {
  description = "t4g.small: 2 vCPU (burstable), 2 GiB, arm64; free trial until 2026-12-31."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_gb" {
  description = "Billed even while stopped (~$0.095/GB-month in eu-central-1)."
  type        = number
  default     = 12
}
