#!/bin/sh
# #23: vulnerability scan of a lab-api image with the hash-pinned trivy.
#
#   scripts/scan-image.sh <image>
#
# Fails (exit 1) only on HIGH or CRITICAL vulnerabilities that HAVE a fix: rebuilding on
# a newer base or bumping a package resolves those. Findings without a fix (Debian
# status "affected", no fixed version) are reported but do not fail the build: nothing
# can be done about them short of changing distro, and a gate that is always red gets
# switched off. Accepted exceptions go in .trivyignore.yaml, each with a reason and an
# expiry date.
#
# SCAN_IMAGE_SRC: where trivy reads the image. "docker" (default; CI scans the image it
# just built, before pushing) or "remote" (straight from the registry; needed on Docker
# Desktop, whose containerd image store trivy cannot read).
set -eu

image=${1:?usage: $0 <image>}
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
TRIVY=$(fetch_tool trivy)

src=${SCAN_IMAGE_SRC:-docker}
report=$(mktemp)
trap 'rm -f "$report"' EXIT

# The vulnerability database is data and must be fresh (it is not pinned). Two
# registries: if ghcr.io rate-limits the download, trivy falls back to ECR Public.
set -- --quiet --scanners vuln --image-src "$src" --platform linux/arm64 \
  --ignorefile .trivyignore.yaml \
  --db-repository ghcr.io/aquasecurity/trivy-db:2,public.ecr.aws/aquasecurity/trivy-db:2

# 1. Report: every finding, fixable or not, as counts (and the GitHub job summary in CI).
"$TRIVY" image "$@" --format json --output "$report" "$image"
summary=$(jq -r '
  [.Results[]?.Vulnerabilities[]?] as $v
  | ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
  | map(. as $s | [$v[] | select(.Severity == $s)]
        | "| \($s) | \(length) | \([.[] | select((.FixedVersion // "") != "")] | length) |")
  | join("\n")' "$report")
printf '\nAll findings for %s\n| Severity | Total | With a fix |\n|---|---|---|\n%s\n' \
  "$image" "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # the backticks are Markdown, not command substitution
  printf '### Vulnerabilities\n\n`%s`\n\n| Severity | Total | With a fix |\n|---|---|---|\n%s\n\nThe build fails only on HIGH/CRITICAL **with a fix**.\n' \
    "$image" "$summary" >>"$GITHUB_STEP_SUMMARY"
fi

# 2. Gate: HIGH/CRITICAL with a fix available. Same database, no second download.
printf '\nGate: HIGH/CRITICAL with a fix available\n'
"$TRIVY" image "$@" --skip-db-update --ignore-unfixed --severity HIGH,CRITICAL \
  --exit-code 1 --format table "$image"
echo "scan: no fixable HIGH/CRITICAL vulnerabilities in $image"
