provider "aws" {
  region = var.region

  # Hard guard: refuse to run against any other account. The laptop's `default` AWS
  # profile is an employer production account; always run with AWS_PROFILE=personal.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "k3s-gitops-lab"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
      Repo      = "github.com/sabocalin/k3s-gitops-lab"
    }
  }
}
