terraform {
  # 1.15+: the S3 backend understands `aws login` sessions (1.10 added use_lockfile).
  # Older versions fail backend init with "No valid credential sources found".
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66" # any 6.x from 6.66 on; the exact build is pinned in .terraform.lock.hcl
    }
  }

  # This stack creates the bucket it stores its own state in. First apply ran with local
  # state; this block was added afterwards and the state moved with
  # `terraform init -migrate-state`. See docs/learning/8-terraform-bootstrap.md.
  backend "s3" {
    bucket       = "k3s-gitops-lab-tfstate-466558795290"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true # S3 native locking (Terraform 1.10+); no DynamoDB table
  }
}
