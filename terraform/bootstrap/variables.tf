variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  description = "Region for the state bucket and everything else in this project."
  type        = string
  default     = "eu-central-1"
}

variable "alert_email" {
  description = "Where budget alerts and AWS alternate-contact mail go. Set in terraform.tfvars (git-ignored); the repo is public."
  type        = string
  sensitive   = true # keeps it out of plan output and CI logs

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an email address."
  }
}

variable "alert_name" {
  description = "Name shown on the AWS alternate contacts."
  type        = string
  default     = "Calin Sabo"
}

variable "alert_phone" {
  description = "Phone for the AWS alternate contacts (required by the API; AWS may call about security incidents). Set in terraform.tfvars."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^\\+[0-9 ()-]{6,24}$", var.alert_phone))
    error_message = "alert_phone must start with + and the country code, e.g. +40 7xx xxx xxx."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget. Expected spend is ~$1.35-2.10 (README cost model)."
  type        = number
  default     = 5
}
