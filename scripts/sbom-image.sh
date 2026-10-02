#!/bin/sh
# #24: write a CycloneDX SBOM (every OS package and Python wheel in the image) with the
# hash-pinned trivy. CI attests it (actions/attest) next to the image in GHCR.
#
#   scripts/sbom-image.sh <image> <output.cdx.json>
#
# SCAN_IMAGE_SRC as in scan-image.sh: "docker" (default, CI) or "remote" (Docker Desktop).
set -eu

image=${1:?usage: $0 <image> <output file>}
out=${2:?usage: $0 <image> <output file>}
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
TRIVY=$(fetch_tool trivy)

"$TRIVY" image --quiet --format cyclonedx --output "$out" \
  --image-src "${SCAN_IMAGE_SRC:-docker}" --platform linux/arm64 "$image"

jq -r '"sbom: \(.bomFormat) \(.specVersion), \(.components | length) components " +
  "(\([.components[] | select(.purl // "" | startswith("pkg:deb"))] | length) Debian, " +
  "\([.components[] | select(.purl // "" | startswith("pkg:pypi"))] | length) Python) -> '"$out"'"' "$out"
