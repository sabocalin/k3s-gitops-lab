#!/bin/sh
# #25: verify an image's cosign signature against the ONE identity allowed to sign it:
# this repo's image workflow on main, authenticated by GitHub Actions' OIDC issuer.
# Anyone can run it; no credentials needed (public image, public Sigstore).
#
#   scripts/verify-image.sh <image>@sha256:<digest>
#
# Exits non-zero unless the signature verifies AND the signing certificate names
# exactly that workflow and issuer: a valid signature from anyone else is rejected.
set -eu

ref=${1:?usage: $0 <image>@sha256:<digest>}
case $ref in *@sha256:*) ;; *) echo "verify: use a digest reference (…@sha256:…), not a tag" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
COSIGN=$(fetch_tool cosign)

IDENTITY=${VERIFY_IDENTITY:-https://github.com/sabocalin/k3s-gitops-lab/.github/workflows/image.yml@refs/heads/main}
ISSUER=${VERIFY_ISSUER:-https://token.actions.githubusercontent.com}

# cosign 3 counts EVERY Sigstore bundle for this digest from this identity as a valid
# signature, including the #24 attestations (provenance, SBOM). Those alone would make an
# unsigned image pass, so require at least one bundle of cosign's own signature type.
SIGN_TYPE=https://sigstore.dev/cosign/sign/v1

out=$("$COSIGN" verify "$ref" \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  --output json)
echo "$out" | jq -r '.[] | "  found: \(.critical.type) for \(.critical.image["docker-manifest-digest"])"'
if ! echo "$out" | jq -e --arg t "$SIGN_TYPE" 'any(.[]; .critical.type == $t)' >/dev/null; then
  echo "verify: no cosign signature ($SIGN_TYPE) from $IDENTITY; only other signed statements" >&2
  exit 1
fi
echo "verified: $ref is signed by $IDENTITY (issuer $ISSUER)"
