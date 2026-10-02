# 23 · Image vulnerability scan: fail on fixable HIGH/CRITICAL

> Issue: #23 (2.5) · Phase 2

## What
`scripts/scan-image.sh` scans the image CI just built with trivy (hash-pinned 0.74.0),
**before** the smoke test and **before** any push. It reports every finding and fails the
build on HIGH or CRITICAL vulnerabilities **that have a fix**.

## Why
The image carries an operating system (Debian 13 in distroless) and Python packages; both
get CVEs. Scanning before the push means a known-vulnerable image never reaches GHCR,
and so never reaches the cluster.

**The key decision, fixable only.** The image on `main` had 26 HIGH findings and no
CRITICAL, and **every one had no fix in Debian 13** (`status=affected`, no fixed version:
libexpat, libpython3.13, ncurses, libuuid). Failing on those would block every build with
nothing anyone can do short of changing distro, and a gate that is always red gets switched
off. Every *fixable* finding has an action: rebuild on a newer base, or bump a package.
The unfixed ones stay visible in the report.

Alternatives considered:
- **Fail on every HIGH/CRITICAL** — permanently red today (26 unfixable), as above.
- **Report only, never fail** — a known, fixable CRITICAL would ship.
- **`aquasecurity/trivy-action`** — its tags were hijacked in March 2026; the binary is
  hash-pinned instead (`scripts/lib/tools.sh`).
- **Grype, Docker Scout** — similar results; trivy is already pinned and used for config
  scanning (#17).

## How it works
```
image job: build ─▶ scan-image.sh ─▶ smoke-image.sh ─▶ (main only) push
               1. report: trivy --format json → counts per severity: total / with a fix
                  (log + GitHub job summary)
               2. gate:   trivy --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1
```
- **The vulnerability database is not pinned:** it is data, and a scan with old data misses
  new CVEs. It is downloaded fresh each run from `ghcr.io/aquasecurity/trivy-db`, with
  `public.ecr.aws/aquasecurity/trivy-db` as a fallback when ghcr.io rate-limits. The gate
  reuses it (`--skip-db-update`).
- **Scan before smoke:** it is static, fails fast, and rejects a bad base before anything runs.
- **Exceptions** go in `.trivyignore.yaml` (passed with `--ignorefile`), each with a
  statement and an expiry. None today.
- **`scripts/lib/tools.sh`** (new) holds the pinned versions and hashes for every platform
  (CI x86-64, the arm64 image runner, the laptop); the lint script (#17) sources it too.

## Implementation
`scripts/scan-image.sh`, `scripts/lib/tools.sh` (with the trivy Linux arm64 hash `b94ce197…`,
matched by my download and attested by trivy's release workflow at `v0.74.0`),
`scripts/lint-terraform.sh` (now sources it), `.github/workflows/image.yml` (scan step in
both jobs), `.gitignore` (`!scripts/lib/`).

## Verification
| Run | Image | Result |
|---|---|---|
| local, `SCAN_IMAGE_SRC=remote` | the `main` image `lab-api@sha256:29e42bb5…` | pass: CRITICAL 0; HIGH 26, **0 with a fix** |
| **local, negative** | `python:3.13.0-slim-bookworm` (built 2024-10-18) | **fail**: `Total: 36 (HIGH: 32, CRITICAL: 4)` fixable, e.g. `libssl3 3.0.15 → 3.0.19` |
| PR 37004735080 | this branch | scan pass (HIGH 26 / 0 fixable), smoke pass |
| **PR 37004833342, negative** | final stage `FROM python:3.13.0-slim-bookworm@…` | **`image-build` failed at "Vulnerability scan"**: CRITICAL 9 total / 4 fixable, HIGH 90 / 32, `Total: 36`; smoke and push never ran |
| PR 37004908700 | reverted (`app/` identical to the first commit) | scan pass, smoke pass |
| `terraform-lint` | uses the shared `tools.sh` | pass |

## Gotchas
- **Trivy cannot read Docker Desktop's containerd image store**
  (`unable to get the image's config file ... not found in tar`). Locally, scan from the
  registry: `SCAN_IMAGE_SRC=remote`. The GitHub runner's Docker uses the classic store, so
  `--image-src docker` works there.
- **The Python `.gitignore` template ignores every `lib/` directory**, including
  `scripts/lib/`; `git add` refused until `!scripts/lib/` was added.
- **A scan is a snapshot.** An image that passed today gets new CVEs tomorrow. A scheduled
  rescan of the running image (or the weekly rebuild, #64) covers that.
- **`image-build` cannot be a required check** while it is path-filtered: a docs-only PR
  would never report it and could not merge.

## Further reading
- [Trivy: vulnerability scanning](https://trivy.dev/latest/docs/scanner/vulnerability/)
- [Trivy: `--ignore-unfixed` and `.trivyignore.yaml`](https://trivy.dev/latest/docs/configuration/filtering/)
- [Debian security tracker: "affected" vs "fixed"](https://security-tracker.debian.org/tracker/)
