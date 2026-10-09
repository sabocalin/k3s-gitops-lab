#!/bin/sh
# #49: run Terraform on terraform/grafana with the Grafana service-account token from SSM.
#
#   scripts/tf-grafana.sh plan -out=grafana.tfplan
#   scripts/tf-grafana.sh apply grafana.tfplan
#
# The token goes from SSM into GRAFANA_AUTH for this one process only. It is never
# printed, written to disk, or put in Terraform state (the provider reads the variable;
# no Terraform variable or data source holds it).
set -eu
: "${AWS_PROFILE:=personal}"
export AWS_PROFILE AWS_REGION=eu-central-1 AWS_PAGER=""
account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = 466558795290 ] || { echo "not the lab account; refusing" >&2; exit 1; }
GRAFANA_AUTH=$(aws ssm get-parameter --name /k3s-gitops-lab/grafana-cloud/terraform-token \
  --with-decryption --query Parameter.Value --output text)
export GRAFANA_AUTH
cd "$(dirname "$0")/../terraform/grafana"
exec terraform "$@"
