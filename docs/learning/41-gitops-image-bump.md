# 41 · CI bumps the image in the gitops overlay (a bot PR that merges itself)

> Issue: #41 (4.4) · Phase 4

## What
After every image publish, a job in `image.yml` points `k8s/overlays/gitops` at the new
digest. It runs `kustomize edit set image`, makes one **signed** commit on a
`bot/gitops-image-<digest>` branch, and opens a PR with **auto-merge**. The PR merges itself
once the required checks pass, and Argo CD then deploys what `main` says (#42). The actor is
a dedicated **GitHub App**, `k3s-gitops-lab-bot`.

## Why
In the pull model, git is the source of truth for what runs. So a new build has to become
a git change, not a `kubectl set image`. The `main` ruleset (#6) requires a PR with passing
checks and signed commits, with no bypass for anyone, so the bot goes through the same door
as a human.

Alternatives considered:
- **App on the ruleset's bypass list, committing straight to `main`**: fewer moving parts,
  but the first hole in the ruleset; a leaked key writes `main` with no checks.
- **The job's own `GITHUB_TOKEN` opening the PR**: no extra secret, but events caused by
  `GITHUB_TOKEN` don't start workflows (GitHub's guard against workflow loops). The
  required checks would never run and the PR could never merge, unless the job dispatches
  each check workflow itself, which is a fragile workaround.
- **A separate gitops-state branch**: no PR needed, but it drifts from `main`'s base
  manifests, and "one commit updates both namespaces" (#44) stops being true.
- **Argo CD Image Updater**: watches the registry and writes back to git itself. Another
  controller in the cluster and another credential, for something CI already knows.

## How it works
```
merge to main (app/** …) ─▶ image.yml
  image-publish (#22–#25): build, scan, smoke, push, attest, sign ─▶ output: digest
  gitops-bump (environment production, needs: image-publish):
    checkout latest main ─▶ verify-image.sh (signed by image.yml?)
    create-github-app-token: client ID + private key ─▶ installation token for THIS repo,
        contents:write + pull-requests:write only, 1 h, revoked at job end
    bump-gitops-image.sh:
      kustomize edit set image (in k8s/overlays/gitops/image only) ─▶ render-k8s.sh
      POST git/refs  bot/gitops-image-<12 hex> from current main
      GraphQL createCommitOnBranch ─▶ one commit, signed by GitHub ("Verified")
      gh pr create ─▶ close older open bump PRs ("Superseded by …")
      gh pr merge --auto --squash
  PR (opened by the App, so pull_request workflows run): zizmor, terraform-lint, ruff,
     pytest, k8s-render ─▶ all green ─▶ GitHub squash-merges (signed) ─▶ branch deleted
```
- **Why an App and not a token of yours:** an App is its own identity with its own
  permissions, installed on one repository. Its key mints short-lived installation tokens;
  nothing long-lived ever reaches a step.
- **Why createCommitOnBranch:** commits made through the API are signed by GitHub. A `git
  commit` + `git push` on the runner would be unsigned, which the issue rules out.
- **Superseding:** builds run one at a time, but a bump PR can still be waiting for checks
  when the next build lands. Closing the older one prevents a conflict, or worse, an older
  build merging after a newer one.
- **The Component:** `kustomize edit` rewrites the whole file it edits (indentation, key
  order, defaults dropped). The image pin lives in its own Component
  (`k8s/overlays/gitops/image`), in kustomize's own format, so a bump diff is one line.

## Implementation
- `k8s/overlays/gitops/image/kustomization.yaml` (`kind: Component`): the `images:` entry,
  owned by the bot. `k8s/overlays/gitops/kustomization.yaml`: `components: [image]`
  instead of an inline `images:`. Render before and after: identical.
- `scripts/bump-gitops-image.sh`: the steps above; exits early if gitops already runs the
  digest or the branch exists (re-run); runs `render-k8s.sh` before opening anything.
- `.github/workflows/image.yml`: `image-publish` exports `digest`. A new job,
  **`gitops-bump`**:
  - `needs: publish`, `environment: production`, job permissions `contents: read` only (all
    writes use the App's token);
  - `actions/create-github-app-token` pinned (v3.2.0), with `permission-contents: write` and
    `permission-pull-requests: write`;
  - zizmor: no findings.
- `.github/workflows/ai-review.yml`: bump PRs (`bot/gitops-image-*`) skip the automatic
  review. The `ai-review` label still triggers it.
- **Repository settings:** "Allow auto-merge" on; "Automatically delete head branches" on.
- **GitHub App** `k3s-gitops-lab-bot`: Contents and Pull requests read/write, no webhook,
  installed on this repository only. `BOT_APP_CLIENT_ID` (environment variable) and
  `BOT_APP_PRIVATE_KEY` (environment secret) on `production`.

## Verification
Before the merge (the job runs only on `main`, after a publish):

| Check | Result |
|---|---|
| gitops render with the Component vs the inline `images:` | identical |
| `kustomize edit set image` with the current digest on the new Component | no diff (already in kustomize's format, so a bump is a one-line diff) |
| `make k8s` | all overlays and platform components OK |
| zizmor 1.30.1 on `image.yml`, `ai-review.yml` | no findings |
| `sh -n scripts/bump-gitops-image.sh` | ok |
| Repository settings via the API | `allow_auto_merge=true`, `delete_branch_on_merge=true`, squash only |

This PR (#109) changes `image.yml`, so its merge triggered a build, a publish, and the
bot's first bump PR. After the merge (image run 37770533048, recorded with #42):

| Check | Result |
|---|---|
| `image-publish` → `gitops-bump` | publish 11:30:52–11:31:57 UTC, bump 11:32:03–11:32:23 |
| Bump PR | #110, opened by `app/k3s-gitops-lab-bot`, branch `bot/gitops-image-9186280ad5e3` |
| Bot commit `dd60f49` | author `k3s-gitops-lab-bot[bot]`, **Verified** (`valid`) |
| Required checks on #110 | all green; auto-merge squashed it **38 s** after it opened (11:32:17 → 11:32:55) |
| Merge commit `4db8663` | committer GitHub, **Verified** |
| Head branch | deleted (`404` on the branch API) |
| Workflows on `4db8663` | k8s, zizmor, terraform-lint, app-ci; **no `image.yml` run**, so no loop |
| `make k8s` on the new `main` | OK; the gitops overlay pins `sha256:9186280a…` |
| Deployed by Argo CD (#42) | `gitops` runs 3/3 pods on `9186280a…`, synced from `4db8663` |

## Gotchas
- **`GITHUB_TOKEN` can't open a PR that ever merges here**, because its events start no
  workflows, so required checks never report. That's the whole reason for the App.
- **`kustomize edit` reformats the entire file**: comments survive, but lists re-indent,
  keys reorder and `includeSelectors: false` (the default) disappears. Hence the
  bot-owned Component.
- **The App's private key is this project's one long-lived secret in GitHub.** It lives as a
  `production` environment secret, so only `main` jobs see it. The tokens it mints are
  scoped to this repository and two permissions, and last an hour. Rotate by generating a
  new key on the App page and deleting the old one.
- **Auto-merge and branch deletion are repository settings**, not code. A fresh fork or
  re-created repository needs them switched on again.
- **Merging a bump PR is a push to `main` made by GitHub on the App's behalf.** It triggers
  the usual `push` workflows (k8s, zizmor…), but not `image.yml` (its paths don't include
  `k8s/`), so there's no build loop.

## Further reading
- [GitHub: making authenticated API requests with a GitHub App in Actions](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow)
- [GitHub: triggering a workflow from a workflow (GITHUB_TOKEN limits)](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow)
- [GraphQL: createCommitOnBranch](https://docs.github.com/en/graphql/reference/mutations#createcommitonbranch)
- [Kustomize components](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
