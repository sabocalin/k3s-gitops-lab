terraform {
  # 1.15+: the S3 backend understands `aws login` sessions.
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66" # exact build pinned in .terraform.lock.hcl
    }
  }

  backend "s3" {
    bucket       = "k3s-gitops-lab-tfstate-466558795290"
    key          = "instance/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
