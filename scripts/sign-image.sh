#!/bin/sh
# #25: sign a pushed image with cosign, keyless, then check the signature right away.
# Runs in the image workflow on main: the job's OIDC token (id-token: write) gets a
# short-lived Sigstore certificate naming the workflow; the signature is logged in Rekor
# and stored in the registry next to the image. Needs a registry login with push rights.
#
#   scripts/sign-image.sh <image>@sha256:<digest>
set -eu

ref=${1:?usage: $0 <image>@sha256:<digest>}
case $ref in *@sha256:*) ;; *) echo "sign: use a digest reference (…@sha256:…), never a tag" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
COSIGN=$(fetch_tool cosign)

# --yes: no interactive prompt about the public transparency log (this repo is public).
"$COSIGN" sign --yes "$ref"
scripts/verify-image.sh "$ref"
