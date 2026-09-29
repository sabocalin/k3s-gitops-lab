variable "account_id" {
  description = "The only AWS account this stack may touch (provider allowed_account_ids)."
  type        = string
  default     = "466558795290"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "availability_zone" {
  description = "Single AZ for the single node. t4g.small is offered in all three eu-central-1 AZs."
  type        = string
  default     = "eu-central-1a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.42.1.0/24"
}
