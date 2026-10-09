terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66" # exact build pinned in .terraform.lock.hcl
    }
    grafana = {
      source = "grafana/grafana"
      # Exact: 4.48.0 and 4.49.0 were a day old (7-day cooldown).
      version = "4.47.0"
    }
  }

  backend "s3" {
    bucket       = "k3s-gitops-lab-tfstate-466558795290"
    key          = "grafana/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
