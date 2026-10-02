# 24 · SBOM and build provenance attestations

> Issue: #24 (2.6) · Phase 2

## What
Every image published from `main` carries two **signed attestations**. Both are stored on
GitHub and pushed next to the image in GHCR, and checked with `gh attestation verify`:

| Attestation | Says | Predicate type |
|---|---|---|
| Build provenance (SLSA v1) | this digest was built by `.github/workflows/image.yml` in `sabocalin/k3s-gitops-lab`, from commit X, on a GitHub-hosted runner | `https://slsa.dev/provenance/v1` |
| SBOM (CycloneDX 1.7) | every package inside (38 Debian, 14 Python), each with a package URL | `https://cyclonedx.org/bom` |

## Why
A digest proves *which bytes*; it says nothing about *where they came from*. With
provenance, anyone (later the cluster) can check that an image was built by this repo's CI
from a known commit, not pushed by hand or by a stolen token. The SBOM answers "are we
affected by CVE-X?" from metadata, without pulling or rescanning the image.

Alternatives considered:
- **buildx `--provenance`/`--sbom`** — unsigned, stored in the image index (why #22 disabled
  them), not checkable with `gh attestation verify`.
- **`cosign attest` with a key pair** — a private key to protect and rotate; keyless signing
  is the point (cosign signing itself is #25).
- **SPDX instead of CycloneDX** — both are accepted; CycloneDX is the common choice in
  security tooling.

## How it works
```
publish job ─ build ─ scan ─ smoke ─ sbom-image.sh (trivy → sbom.cdx.json)
            ─ docker login ─ push ─▶ digest sha256:…
            ─ actions/attest (provenance) ─┐
            ─ actions/attest (sbom-path)  ─┤  1. job OIDC token (id-token: write)
                                           │  2. Fulcio: short-lived certificate whose
                                           │     identity is this workflow + ref
                                           │  3. sign the in-toto statement (subject = digest)
                                           │  4. Rekor: public transparency-log entry
                                           └─ 5. store on GitHub (attestations: write)
                                              6. push to GHCR next to the image (OCI referrer)
```
- **Keyless:** no long-lived signing key exists. The certificate is valid for minutes and
  binds the signature to the workflow identity
  (`https://github.com/sabocalin/k3s-gitops-lab/.github/workflows/image.yml@refs/heads/main`).
  Rekor's public log makes a signature that was later deleted or forged detectable.
- **The subject is the digest**, never the tag: an attestation for `sha256:…` stays true
  even if a tag is moved.
- **Public repo, public Sigstore:** the attestation metadata (repo, workflow, commit) is
  public, which is fine because the repo is.

## Implementation
- `scripts/sbom-image.sh` (trivy, `--format cyclonedx`); runs on PRs too, so a broken SBOM
  step fails before merge (not attested there).
- `.github/workflows/image.yml` publish job: `id-token: write`, `attestations: write`; login,
  push (digest as a step output), two `actions/attest` v4.2.2 steps
  (`push-to-registry: true`, `create-storage-record: false`), logout `if: always()`.

## Verification
| Check | Result |
|---|---|
| SBOM locally (published image, `SCAN_IMAGE_SRC=remote`) | CycloneDX 1.7, 53 components (38 Debian, 14 Python), e.g. `pkg:pypi/fastapi@0.141.1` |
| PR run 37007341508 | scan, smoke, SBOM step: all pass |

## Gotchas
- **`create-storage-record` defaults to true** and then needs `artifact-metadata: write`. It
  serves GitHub's artifact metadata feature, which this project does not use, so it is off.
- **`push-to-registry` needs registry credentials during the attest steps**, so the
  `docker logout` moved after them (with `if: always()`).

## Further reading
- [GitHub artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)
- [actions/attest](https://github.com/actions/attest)
- [SLSA provenance v1](https://slsa.dev/spec/v1.0/provenance)
- [Sigstore: Fulcio and Rekor](https://docs.sigstore.dev/about/overview/)
- [CycloneDX](https://cyclonedx.org/specification/overview/)
