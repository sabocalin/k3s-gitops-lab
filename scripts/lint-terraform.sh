#!/bin/sh
# #17: static checks for terraform/, the same locally (make lint) and in CI:
#   terraform fmt and validate, tflint (.tflint.hcl), trivy config (security rules).
# No AWS access: everything reads the code only. Every check runs even if an earlier one
# fails; the script exits 1 if any failed.
#
# tflint and trivy are downloaded at exact versions and checked against SHA-256 hashes
# pinned here, not taken from a third-party action (Trivy's own GitHub Action tags were
# hijacked in March 2026). Bump by hand: new version + both hashes from the release's
# checksums file.
set -eu

TFLINT_VERSION=0.64.0
TRIVY_VERSION=0.74.0

die() {
  printf 'lint: %s\n' "$*" >&2
  exit 1
}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    tflint_asset=tflint_linux_amd64.zip
    tflint_sha256=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
    trivy_asset=trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz
    trivy_sha256=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a
    ;;
  Darwin-arm64)
    tflint_asset=tflint_darwin_arm64.zip
    tflint_sha256=2496e9cb3d24992d553b45e7c87a0fdc9449ca975233876247a9bfeda857e6c0
    trivy_asset=trivy_${TRIVY_VERSION}_macOS-ARM64.tar.gz
    trivy_sha256=1caada5e0e2091909357c7525d3aa76f4b660b13821bc143b190c7483e31cc11
    ;;
  *) die "no pinned tool hashes for $(uname -s)-$(uname -m)" ;;
esac

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TOOLS=${LINT_TOOLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/k3s-gitops-lab/tools}

# No AWS credentials, ever: the checks read code only. Without this, an already
# initialized stack makes `terraform init` load its S3 backend, which on this laptop
# falls back to the `default` profile (an employer account) when AWS_PROFILE is unset.
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Download <url> once into the cache, refuse it unless its hash matches, extract <name>.
fetch() { # <name> <version> <url> <sha256>
  dir=$TOOLS/$1-$2
  if [ ! -x "$dir/$1" ]; then
    mkdir -p "$dir"
    archive=$dir/${3##*/}
    curl -fsSL --retry 3 -o "$archive" "$3"
    actual=$(sha256_of "$archive")
    if [ "$actual" != "$4" ]; then
      rm -f "$archive"
      die "$1 $2: SHA-256 mismatch (expected $4, got $actual); refusing to run it"
    fi
    case $archive in
      *.zip) unzip -oq "$archive" "$1" -d "$dir" ;;
      *.tar.gz) tar -xzf "$archive" -C "$dir" "$1" ;;
    esac
    rm -f "$archive"
  fi
  printf '%s\n' "$dir/$1"
}

TFLINT=$(fetch tflint "$TFLINT_VERSION" \
  "https://github.com/terraform-linters/tflint/releases/download/v$TFLINT_VERSION/$tflint_asset" \
  "$tflint_sha256")
TRIVY=$(fetch trivy "$TRIVY_VERSION" \
  "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/$trivy_asset" \
  "$trivy_sha256")

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
