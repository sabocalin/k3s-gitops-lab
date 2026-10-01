variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  description = "Region for every resource in this stack."
  type        = string
  default     = "eu-central-1"
}

variable "public_subnets" {
  description = "One public subnet per AZ (all free). The instance picks one; when a zone runs out of capacity, switch the instance to another zone."
  type        = map(string)
  default = {
    "eu-central-1a" = "10.42.1.0/24"
    "eu-central-1b" = "10.42.2.0/24"
    "eu-central-1c" = "10.42.3.0/24"
  }
}

variable "vpc_cidr" {
  description = "Address range of the project VPC; subnets are /24s inside it."
  type        = string
  default     = "10.42.0.0/16"
}

