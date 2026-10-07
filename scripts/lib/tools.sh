# shellcheck shell=sh
# Shared by scripts/*.sh (#17, #23): download a pinned tool once into a cache and refuse
# it unless its SHA-256 matches the hash pinned here. Not a third-party action: Trivy's
# own GitHub Action tags were hijacked in March 2026.
# Bump by hand: new version + every platform's hash from the release's checksums file.

TFLINT_VERSION=0.64.0
TRIVY_VERSION=0.74.0
# cosign's own release check: these hashes match cosign_checksums.txt, whose signature
# verifies as keyless@projectsigstore.iam.gserviceaccount.com (issuer accounts.google.com).
COSIGN_VERSION=3.1.3
# kustomize 5.8.1 (5.8.2 was under 7 days old when pinned). No attestation upstream: the
# hashes match the release's checksums.txt and my own download.
KUSTOMIZE_VERSION=5.8.1
# kubectl (#39): the cluster's own version (K3s v1.36.4). Hashes from dl.k8s.io's
# kubectl.sha256 files, matching my own download.
KUBECTL_VERSION=1.36.4
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
    cosign:Linux-aarch64) echo "cosign-linux-arm64 c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a" ;;
    cosign:Linux-x86_64) echo "cosign-linux-amd64 4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71" ;;
    cosign:Darwin-arm64) echo "cosign-darwin-arm64 5cf948c2f4dfe59687bdd0b8523709067383e03982cc543475c8a7dc70e92a76" ;;
    kustomize:Linux-x86_64) echo "kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz 029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d" ;;
    kubectl:Linux-x86_64) echo "bin/linux/amd64/kubectl 8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a" ;;
    kubectl:Linux-aarch64) echo "bin/linux/arm64/kubectl 0ecf44450ee6063bf19dd166a103ee6df4a9034455c2abce626e6eea657d73fb" ;;
    kubectl:Darwin-arm64) echo "bin/darwin/arm64/kubectl c9e4f713d6fee0043a3d835cca13077cda2bc0973840eb9779360df0b5bdfc69" ;;
    kustomize:Darwin-arm64) echo "kustomize_v${KUSTOMIZE_VERSION}_darwin_arm64.tar.gz 8886f8a78474e608cc81234f729fda188a9767da23e28925802f00ece2bab288" ;;
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

# fetch_tool <tflint|trivy|cosign|kustomize|kubectl>: prints the path of the verified binary.
fetch_tool() {
  case $1 in
    tflint) version=$TFLINT_VERSION base=https://github.com/terraform-linters/tflint/releases/download/v$TFLINT_VERSION ;;
    trivy) version=$TRIVY_VERSION base=https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION ;;
    cosign) version=$COSIGN_VERSION base=https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION ;;
    kubectl) version=$KUBECTL_VERSION base=https://dl.k8s.io/release/v$KUBECTL_VERSION ;;
    kustomize) version=$KUSTOMIZE_VERSION base=https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv$KUSTOMIZE_VERSION ;;
    *) tools_die "unknown tool $1" ;;
  esac
  pinned=$(tool_asset "$1") || tools_die "no pinned $1 hash for $(uname -s)-$(uname -m)"
  asset=${pinned% *} expected=${pinned#* }
  dir=$TOOLS/$1-$version
  if [ ! -x "$dir/$1" ]; then
    mkdir -p "$dir"
    # Flat local name: some assets are paths (kubectl: bin/<os>/<arch>/kubectl).
    archive=$dir/download-$(basename "$asset")
    curl -fsSL --retry 3 -o "$archive" "$base/$asset"
    actual=$(sha256_of "$archive")
    if [ "$actual" != "$expected" ]; then
      rm -f "$archive"
      tools_die "$1 $version: SHA-256 mismatch (expected $expected, got $actual); refusing to run it"
    fi
    case $archive in
      *.zip) unzip -oq "$archive" "$1" -d "$dir" && rm -f "$archive" ;;
      *.tar.gz) tar -xzf "$archive" -C "$dir" "$1" && rm -f "$archive" ;;
      *) mv "$archive" "$dir/$1" && chmod +x "$dir/$1" ;; # a plain binary (cosign, kubectl)
    esac
  fi
  printf '%s\n' "$dir/$1"
}
