#!/bin/sh
# #17: static checks for terraform/, the same locally (make lint) and in CI:
#   terraform fmt and validate, tflint (.tflint.hcl), trivy config (security rules).
# No AWS access: everything reads the code only. Every check runs even if an earlier one
# fails; the script exits 1 if any failed.
#
# tflint and trivy: exact versions, SHA-256 checked (scripts/lib/tools.sh).
set -eu

die() {
  printf 'lint: %s\n' "$*" >&2
  exit 1
}

cd "$(dirname "$0")/.."
ROOT=$(pwd)
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh

# No AWS credentials, ever: the checks read code only. Without this, an already
# initialized stack makes `terraform init` load its S3 backend, which on this laptop
# falls back to the `default` profile (an employer account) when AWS_PROFILE is unset.
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

TFLINT=$(fetch_tool tflint)
TRIVY=$(fetch_tool trivy)

failed=""
step() { printf '\n==> %s\n' "$*"; }
fail() { failed="$failed $1"; }

step "terraform fmt"
terraform fmt -check -recursive -diff terraform || fail fmt

for stack in terraform/*/; do
  stack=${stack%/}
  step "terraform validate $stack"
  # A separate data dir (not the stack's .terraform/), so no existing backend is loaded
  # and a local `terraform plan` setup is left alone. -backend=false: providers only,
  # from the lock file; the plugin cache avoids downloading them for every stack and run.
  data_dir=$TOOLS/tfdata/${stack#terraform/}
  mkdir -p "$TOOLS/plugin-cache"
  if TF_DATA_DIR=$data_dir TF_PLUGIN_CACHE_DIR=$TOOLS/plugin-cache \
    terraform -chdir="$stack" init -backend=false -input=false >/dev/null; then
    TF_DATA_DIR=$data_dir terraform -chdir="$stack" validate -no-color || fail "validate:$stack"
  else
    fail "init:$stack"
  fi
done

step "tflint $TFLINT_VERSION"
"$TFLINT" --init --config="$ROOT/.tflint.hcl" >/dev/null
(cd terraform && "$TFLINT" --recursive --config="$ROOT/.tflint.hcl" --format=compact) || fail tflint

step "trivy config $TRIVY_VERSION"
# --skip-check-update: use the checks built into this exact binary instead of downloading
# the latest rules bundle, so a result only changes when the pinned version does.
"$TRIVY" config --quiet --skip-check-update --exit-code 1 terraform || fail trivy

if [ -n "$failed" ]; then
  printf '\nFAILED:%s\n' "$failed"
  exit 1
fi
printf '\nall Terraform checks passed\n'
