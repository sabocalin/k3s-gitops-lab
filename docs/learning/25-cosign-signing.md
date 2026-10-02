# 25 · Keyless cosign signing

> Issue: #25 (2.7) · Phase 2

## What
Every image published from `main` gets a **cosign signature** over its digest, keyless,
stored in GHCR next to the image. `scripts/verify-image.sh <image>@sha256:<digest>` checks
it from anywhere, without credentials, and accepts exactly one signer: this repo's image
workflow on `main`, as authenticated by GitHub Actions' OIDC issuer.

## Why
#24's attestations are *statements* about the image (how it was built, what is inside). A
cosign signature is the plain "this digest was published by X" that Kubernetes admission
controllers (Kyverno `verifyImages`, Sigstore policy-controller) check before a pod may
start. It is the hook for "the cluster runs only images CI signed" (Phase 3+).

Alternatives considered:
- **cosign with a key pair** — a private key to store as a secret, protect and rotate; a
  leaked key signs anything. Keyless ties every signature to a workflow identity and a
  public log entry.
- **Notation (Notary v2)** — needs a certificate authority or key management; Sigstore
  keyless needs neither.
- **Attestations only (#24)** — they work for `gh attestation verify`, but most admission
  policies look for a cosign signature.

## How it works
```
publish job (id-token: write) ─▶ cosign sign --yes <image>@sha256:…
    OIDC token ─▶ Fulcio: certificate (minutes) with
                  SAN    = https://github.com/sabocalin/k3s-gitops-lab/.github/workflows/image.yml@refs/heads/main
                  issuer = https://token.actions.githubusercontent.com
    sign the digest ─▶ Rekor (public log) ─▶ bundle into GHCR (index tagged sha256-<digest>)
verify-image.sh ─▶ cosign verify --certificate-identity <SAN> --certificate-oidc-issuer <issuer>
                ─▶ AND at least one bundle of type https://sigstore.dev/cosign/sign/v1
```
- **Identity, not key:** verification pins *who* signed (workflow path and ref) and *who
  vouched for that* (the issuer). A valid signature from any other workflow, branch or repo
  is rejected.
- **Digest, never tag:** both scripts refuse a tag reference. A tag can be moved; a signed
  digest cannot change.
- **Where the bundles live:** GHCR has no OCI referrers API (it returns 404), so Sigstore
  bundles use the OCI 1.1 fallback: an index tagged `sha256-<digest>`. That is why such a tag
  appears next to the SHA tags (it is not an image).
- **cosign itself is trusted by its own release check:** the pinned hashes match
  `cosign_checksums.txt`, whose Sigstore signature verifies as
  `keyless@projectsigstore.iam.gserviceaccount.com` (issuer `accounts.google.com`: cosign
  releases are built on Google Cloud Build). A tampered copy of that file:
  `invalid signature when validating ASN.1 encoded signature`.

## Implementation
- `scripts/lib/tools.sh`: cosign 3.1.3 (plain binaries for Linux arm64/x86-64 and macOS).
- `scripts/sign-image.sh`: `cosign sign --yes`, then `verify-image.sh` on the same digest.
- `scripts/verify-image.sh`: identity + issuer pinned (overridable through `VERIFY_IDENTITY` /
  `VERIFY_ISSUER`, for negative tests), and the signature-type check.
- `.github/workflows/image.yml`: a sign-and-verify step after the attestations, while still
  logged in to GHCR; the digest is passed through `env:` (never interpolated into the script).

## Verification
| Check | Result |
|---|---|
| cosign release check | `Verified OK`; tampered checksums: `invalid signature` |
| **Negative: tag instead of digest** | `verify: use a digest reference (…@sha256:…), not a tag` (exit 2) |
| **Negative: image with nothing attached** (pre-#24, `29e42bb5…`) | `no signatures found` (exit 10) |
| **Negative: image with attestations but no cosign signature** (`b4efe43a…`) | found `slsa.dev/provenance/v1` and `cyclonedx.org/bom`, then `no cosign signature (https://sigstore.dev/cosign/sign/v1) …` (exit 1) |
| `main` run 37010706686 (merge `d123520`) | pushed `lab-api@sha256:e57c89b448a7b83ed068a556d285ef1e24b7f5b3879efb4491b2facdf7012ccb`; the sign step's own check found `sign/v1`, `cyclonedx.org/bom`, `slsa.dev/provenance/v1` and printed `verified` |
| **Positive, from the laptop** (empty `DOCKER_CONFIG`: no credentials) | `verified: … signed by …/image.yml@refs/heads/main (issuer https://token.actions.githubusercontent.com)`, exit 0; plain `cosign verify` with that identity and issuer finds the `sign/v1` bundle |
| **Negative: another workflow** (`app-ci.yml@refs/heads/main`) | exit 1: `expected SAN value ".../app-ci.yml@refs/heads/main", got ".../image.yml@refs/heads/main"` |
| **Negative: right workflow, another branch** (`@refs/heads/feature`) | exit 1: `expected SAN value ".../image.yml@refs/heads/feature", got ".../image.yml@refs/heads/main"` |
| **Negative: another issuer** (`accounts.google.com`) | exit 1: `expected issuer value "https://accounts.google.com", got "https://token.actions.githubusercontent.com"` |

## Gotchas
- **cosign 3 `verify` passed an image nobody had signed.** The first version of the
  negative control *succeeded*: cosign 3 treats every Sigstore bundle for the digest from the
  given identity as a signature, and the #24 provenance and SBOM bundles came from the same
  workflow. True as a statement ("this identity signed something about this digest"), but
  useless as a gate. `verify-image.sh` now also requires a bundle of cosign's own type
  (`CosignSignPredicateType` in cosign's `pkg/types/predicate.go`). Admission policies need the
  same care.
- **cosign's release signer is not GitHub Actions.** Its `cosign_checksums.txt` bundle is
  signed by a Google service account; `--certificate-identity` takes the address without the
  `email:` prefix that `openssl` prints.
- **`cosign verify-blob --bundle <(curl …)`** failed with `proto: syntax error`; download the
  bundle to a file first.

## Further reading
- [cosign keyless signing](https://docs.sigstore.dev/cosign/signing/overview/)
- [cosign verify: identity flags](https://docs.sigstore.dev/cosign/verifying/verify/)
- [Verifying cosign releases](https://docs.sigstore.dev/cosign/system_config/installation/#verifying-cosign-releases)
- [OCI 1.1 referrers fallback (tag schema)](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#referrers-tag-schema)
- [Kyverno verifyImages](https://kyverno.io/docs/writing-policies/verify-images/)
