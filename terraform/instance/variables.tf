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
  # #40: t4g.small (2 GiB, free trial) thrashed with Argo CD running: swap ~850 Mi, memory
  # PSI ~30%, the #47 gate failed. t4g.medium: 4 GiB, ~$0.0384/h (not in the trial).
  # Changing the type is an in-place stop, modify, start; the disk and cluster stay.
  description = "t4g.medium: 2 vCPU (burstable), 4 GiB, arm64 (#40, docs/learning/47-memory-headroom.md)."
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_gb" {
  description = "Billed even while stopped (~$0.095/GB-month in eu-central-1)."
  type        = number
  default     = 12
}
