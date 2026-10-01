variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  description = "Region of the node (must match the platform stack)."
  type        = string
  default     = "eu-central-1"
}

variable "availability_zone" {
  description = "Zone to run in; must be a key of the platform's public_subnet_ids. eu-central-1a ran out of t4g.small capacity on 2026-09-30; switching zones replaces the instance."
  type        = string
  default     = "eu-central-1b"
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
