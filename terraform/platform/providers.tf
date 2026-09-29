provider "aws" {
  region = var.region

  # Hard guard: refuse any other account (the laptop's `default` profile is an employer
  # production account). Always run with AWS_PROFILE=personal.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "k3s-gitops-lab"
      Stack     = "platform"
      ManagedBy = "terraform"
      Repo      = "github.com/sabocalin/k3s-gitops-lab"
    }
  }
}
