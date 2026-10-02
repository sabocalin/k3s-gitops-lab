# 22 · Native arm64 image build, pushed to GHCR by git SHA

> Issue: #22 (2.4) · Phase 2

## What
The `image` workflow builds `app/Dockerfile` on GitHub's **`ubuntu-24.04-arm`** runner.
On a PR it builds and smoke-tests the image. On `main` it does the same, then pushes
`ghcr.io/sabocalin/k3s-gitops-lab/lab-api:<full git SHA>`. There is no `:latest` tag.

## Why
- **Native arm64:** the node is a Graviton t4g. On an x86 runner, arm64 means QEMU
  emulation: several times slower, occasionally flaky. The arm runner is free for public
  repos; the whole PR job took 20 s.
- **SHA tags only:** every image is exactly one commit, rollback means naming an older
  SHA, and nothing changes under a tag a pod has already pulled. `:latest` would say none
  of that.
- **GHCR:** free for public packages, and the node pulls anonymously, so the cluster
  needs no registry secret.

Alternatives considered:
- **x86 runner + QEMU** — emulation, as above.
- **Docker Hub** — anonymous pulls are rate-limited; another account.
- **ECR** — costs money; the node would need IAM pull permissions.
- **`docker/build-push-action`** — another action to trust; the runner's `docker buildx`
  CLI does the same, and every flag is visible in the workflow.

## How it works
```
PR (app/**)   image-build    contents: read            build ─▶ smoke test   (no push)
push to main  image-publish  contents: read,           build ─▶ smoke test ─▶ docker login
                             packages: write                  ─▶ docker push lab-api:<sha>
```
- **`--build-arg APP_VERSION=$GITHUB_SHA`** is baked in as an environment variable, so `/`
  answers with the commit it was built from.
- **`--provenance=false --sbom=false`:** by default buildx wraps a single-platform image in
  an index with an extra `unknown/unknown` attestation entry. Without it the tag is one plain
  arm64 manifest. Provenance and SBOM come as GitHub attestations in #24.
- **`org.opencontainers.image.source` label:** GHCR links the package to this repository.
- **The smoke test gates the push.** `scripts/smoke-image.sh` checks the image from outside,
  with a read-only filesystem: `/health` 200; `/ready` 503 during warm-up, then 200; `/`
  reports the expected SHA; `/metrics` 200; UID 65532; no shell.
- **Login:** the job's own short-lived `GITHUB_TOKEN`, through `--password-stdin` (never on
  the command line), and `docker logout` right after the push.
- **Concurrency:** superseded PR builds are cancelled; a push on `main` is never cancelled
  halfway.
- **Path filters** (`app/**`, the smoke script, the workflow): fine here because `image` is
  not a required check; docs-only merges do not rebuild the image.

## Implementation
- `.github/workflows/image.yml`, `scripts/smoke-image.sh`, `app/Dockerfile`
  (`ARG APP_VERSION`).

## Verification
| Check | Result |
|---|---|
| Smoke test locally | all 7 checks `ok` |
| **Negative: wrong expected version** | `FAIL: / should report version something-else, got: {"...version":"local-test"...}` |
| **Negative: run as root** (`SMOKE_RUN_ARGS="--user 0"`) | `FAIL: process should run as UID 65532, got '0'` |
| PR run 37002294063 | `image-build` on `ubuntu-24.04-arm`, 20 s: build, then smoke test with the commit SHA: all `ok`; `image-publish` skipped |
| `main` run 37002939675 (merge `928322f`) | `image-publish`: smoke test passed, then pushed `lab-api@sha256:29e42bb5cc593a82813abc90e4e7e0d4cacd007b50f91762cec899ecd6a50532` |
| **Public, from the consumer's side** | anonymous registry token works; tags: only `928322f2dcc5e81e397eedb946e40a98190c0893` |
| arm64 manifest | `application/vnd.docker.distribution.manifest.v2+json`, config `linux/arm64`, user `65532:65532`, `APP_VERSION` = the SHA, labels `source` + `revision` |
| **Negative: `:latest`** | `GET manifests/latest` → HTTP 404 |
| Anonymous pull + smoke test | `DOCKER_CONFIG` = an empty directory (no saved logins): `docker pull` by digest worked; smoke test on the pulled image: all checks passed |

## Gotchas
- **`docker top -eo uid` fails** with `Couldn't find PID field in ps output`: Docker needs a
  `pid` column in the list; use `-eo uid,pid`.
- **A negative control must reach the check it targets.** Running the smoke test against
  `python:3.13-slim` failed at `/health` (no app), before the UID and shell checks; it proved
  nothing about them. `--user 0` on the real image reaches the UID check.

- **The package came out public on the first push.** It is linked to this public repo (the
  `source` label, pushed with the repo's `GITHUB_TOKEN`) and took the repo's visibility; no
  manual switch was needed.

## Further reading
- [GitHub-hosted arm64 runners](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners#standard-github-hosted-runners-for-public-repositories)
- [Publishing to GHCR from Actions](https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)
- [buildx: provenance and SBOM attestations](https://docs.docker.com/build/metadata/attestations/)
- [OCI image annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
