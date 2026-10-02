# shellcheck shell=sh
# Shared by scripts/*.sh (#17, #23): download a pinned tool once into a cache and refuse
# it unless its SHA-256 matches the hash pinned here. Not a third-party action: Trivy's
# own GitHub Action tags were hijacked in March 2026.
# Bump by hand: new version + every platform's hash from the release's checksums file.

TFLINT_VERSION=0.64.0
TRIVY_VERSION=0.74.0
TOOLS=${LINT_TOOLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/k3s-gitops-lab/tools}

tools_die() {
  printf 'tools: %s\n' "$*" >&2
  exit 1
}

# <tool> -> "<release asset> <sha256>" for this machine. Linux-x86_64: CI (ubuntu-24.04);
# Linux-aarch64: the arm64 image runner (#22); Darwin-arm64: the laptop.
tool_asset() {
  case "$1:$(uname -s)-$(uname -m)" in
    tflint:Linux-x86_64) echo "tflint_linux_amd64.zip cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537" ;;
    tflint:Darwin-arm64) echo "tflint_darwin_arm64.zip 2496e9cb3d24992d553b45e7c87a0fdc9449ca975233876247a9bfeda857e6c0" ;;
    trivy:Linux-x86_64) echo "trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz 2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a" ;;
    trivy:Linux-aarch64) echo "trivy_${TRIVY_VERSION}_Linux-ARM64.tar.gz b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5" ;;
    trivy:Darwin-arm64) echo "trivy_${TRIVY_VERSION}_macOS-ARM64.tar.gz 1caada5e0e2091909357c7525d3aa76f4b660b13821bc143b190c7483e31cc11" ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch_tool <tflint|trivy>: prints the path of the verified binary.
fetch_tool() {
  case $1 in
    tflint) version=$TFLINT_VERSION base=https://github.com/terraform-linters/tflint/releases/download/v$TFLINT_VERSION ;;
    trivy) version=$TRIVY_VERSION base=https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION ;;
    *) tools_die "unknown tool $1" ;;
  esac
  pinned=$(tool_asset "$1") || tools_die "no pinned $1 hash for $(uname -s)-$(uname -m)"
  asset=${pinned% *} expected=${pinned#* }
  dir=$TOOLS/$1-$version
  if [ ! -x "$dir/$1" ]; then
    mkdir -p "$dir"
    archive=$dir/$asset
    curl -fsSL --retry 3 -o "$archive" "$base/$asset"
    actual=$(sha256_of "$archive")
    if [ "$actual" != "$expected" ]; then
      rm -f "$archive"
      tools_die "$1 $version: SHA-256 mismatch (expected $expected, got $actual); refusing to run it"
    fi
    case $archive in
      *.zip) unzip -oq "$archive" "$1" -d "$dir" ;;
      *.tar.gz) tar -xzf "$archive" -C "$dir" "$1" ;;
    esac
    rm -f "$archive"
  fi
  printf '%s\n' "$dir/$1"
}
