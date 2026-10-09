provider "aws" {
  region = var.region

  # Hard guard: refuse any other account (the laptop's `default` profile is an employer
  # production account). Always run through scripts/tf-grafana.sh.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "k3s-gitops-lab"
      Stack     = "grafana"
      ManagedBy = "terraform"
      Repo      = "github.com/sabocalin/k3s-gitops-lab"
    }
  }
}

# Authenticates with a Grafana service-account token (role Editor) from the environment
# variable GRAFANA_AUTH, which scripts/tf-grafana.sh fills from SSM for the one command.
# Not a variable or a data source on purpose: either would store the token in the state.
provider "grafana" {
  url = var.grafana_url
}
