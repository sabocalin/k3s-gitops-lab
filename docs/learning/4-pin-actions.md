# 4 · Pin all GitHub Actions to a commit SHA

> Issue: #4 · PR: #59 · Phase 0

## What
Every `uses:` in a workflow references an action by its full 40-character commit SHA
instead of a tag like `@v7`. Two independent layers enforce it:

| Layer | When it acts | What it does |
|---|---|---|
| GitHub Actions policy `sha_pinning_required` | When a job starts | Refuses to run any job that uses a non-SHA action reference |
| [zizmor](https://docs.zizmor.sh/) workflow, a required status check | On every PR | Static security audit of all workflows; fails the PR on any finding, which blocks the merge |

## Why
**Tags are mutable, commits are not.** `actions/checkout@v7` means "whatever commit the
`v7` tag points to right now". The action's owner, or anyone who compromises the
owner's account, can move that tag to a different commit, and every workflow using
`@v7` runs the new code on its next run, with access to that workflow's secrets and
token.

This is not theoretical. In March 2025 the popular `tj-actions/changed-files` action
had its version tags repointed to a malicious commit that printed CI secrets into
workflow logs (CVE-2025-30066). Every repo pinned by tag ran it; repos pinned by SHA
did not.

A SHA is a content address: it identifies exactly one tree of files, and changing a
single byte gives a different SHA. Pinning by SHA means you run the code you reviewed,
and changes arrive only as a visible diff (a Dependabot PR).

Why two layers:
- The **platform policy** is unskippable, but it only acts when a job runs, only checks
  pinning, and says nothing on a PR that adds a workflow that doesn't run yet.
- **zizmor** reviews every workflow on every PR, whether it runs or not, and checks much
  more than pinning (below). But a linter is only as strong as the rule that requires it.

Alternatives considered:
- **Pin to tags + Dependabot** — Dependabot keeps you current but does not protect you
  from a tag being moved.
- **pinact** — rewrites tags into SHAs for you. Useful as a one-off fixer, but it doesn't
  audit anything else.
- **actionlint** — a syntax and shellcheck linter, not a security auditor. Worth adding
  later; it complements zizmor.
- **Vendoring actions into the repo** — full control, but you inherit maintenance of
  every action.

## How it works
- `uses: actions/checkout@3d3c42e…` makes the runner download exactly that commit of the
  action repository. The trailing `# v7.0.1` comment is for humans, and for Dependabot,
  which updates the SHA and the comment together when a new release comes out.
- **Platform policy:** at "Set up job", GitHub resolves each `uses:` reference. If any
  is not a full SHA, the job fails before a single step runs:
  `The action actions/checkout@v7 is not allowed in sabocalin/k3s-gitops-lab because
  all actions must be pinned to a full-length commit SHA.`
- **zizmor** parses every file under `.github/workflows/` plus `dependabot.yml` and runs
  its audits. Some are offline (pure YAML analysis); some are online and use a token
  to query GitHub:
  - `unpinned-uses` — tag or branch references (the reason for this task).
  - `impostor-commit` (online) — the SHA must exist in the action's own repository.
    GitHub shares git objects across a fork network, so a commit that only exists in
    someone's *fork* can still be fetched as `owner/action@<sha>`. A SHA pin is only
    safe if the SHA is really upstream.
  - `known-vulnerable-actions` (online) — the pinned version has a published advisory.
  - `excessive-permissions`, `artipacked` (credentials left in `.git/config`),
    `template-injection` (`${{ }}` expanded inside `run:`), `dependabot-cooldown`, and more.

  It prints findings as GitHub annotations (`--format=github`) and exits non-zero when
  it finds anything, which fails the job.
- **Required status check:** the `main` ruleset requires a successful check named
  `zizmor` **from the GitHub Actions app** (integration id `15368`). If the check is
  missing, pending or failed, the PR cannot merge.

## Implementation
**`.github/workflows/zizmor.yml`**
- Triggers on every `pull_request` and on pushes to `main`. No `paths:` filter: a
  required check that does not run on a PR never reports, and the PR stays blocked
  forever.
- `permissions: {}` at workflow level and only `contents: read` for the job: the
  default-deny pattern. zizmor itself would flag broader permissions.
- `actions/checkout` pinned to `3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, with
  `persist-credentials: false` so the token is not written to `.git/config` where any
  later step could read it.
- `GH_TOKEN: ${{ github.token }}` turns on the online audits. The token is read-only.
- zizmor installed with `pipx run "zizmor==1.30.1"`: exact version, and `pipx` is
  preinstalled on the `ubuntu-24.04` runner.
- `concurrency` cancels superseded runs on the same branch.

**Repository settings (API, not files)**
- Actions permissions: `sha_pinning_required: true`.
- Ruleset `main`: added a `required_status_checks` rule with `zizmor` @ `15368`.
  `strict_required_status_checks_policy: false`, so the branch does not have to be
  rebased on the latest `main` before merging; on a solo repo that only adds clicks.
- Already correct from account defaults, no change: the default `GITHUB_TOKEN` is
  read-only and workflows cannot approve PRs.

**`.github/dependabot.yml`**: cooldown raised from 3 to 7 days (see Gotchas).

## Verification
- Local: `zizmor` on the whole repo with online audits → `No findings to report`,
  exit 0. Same workflow with `@v7` → `error[unpinned-uses]`, exit 14.
- CI positive: the zizmor run on the PR passed (both files audited).
- CI negative control 1 (linter): a `workflow_dispatch`-only workflow using
  `actions/checkout@v7` → zizmor job failed:
  `neg-control.yml:9: unpinned action reference`.
- CI negative control 2 (platform): the zizmor workflow's own checkout changed to `@v7`
  → job failed at "Set up job" with the "must be pinned to a full-length commit SHA" error.
- CI negative control 3 (required check): with zizmor failing, PR merge state was
  `BLOCKED`; after removing the bad file it returned to `CLEAN`.

All three test commits were reverted on the branch and disappear in the squash merge.

## Gotchas
- **zizmor caught a mistake from #3.** The Dependabot cooldown was 3 days; zizmor's
  `dependabot-cooldown` audit requires at least 7. Raised to 7; security updates are
  not delayed by the cooldown, so the only cost is waiting a bit longer for routine bumps.
- **Dependabot cannot see the zizmor version.** It lives in a `run:` command, not a
  manifest. Bump `ZIZMOR_VERSION` by hand now and then.
- **Pinning an action does not pin what the action downloads.** An action pinned by SHA
  can still fetch `latest` of a tool or a Docker image by tag at runtime. The pin
  protects the action's code, not its inputs. This is why the AI reviewer (#57) must
  set `ocr_version` to an exact version even after its action is SHA-pinned.
- **Copying a README snippet (`@v4`) now fails immediately.** Look up the SHA of the
  release (`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`) and keep the version
  as a comment.
- **Integration id matters.** Requiring `zizmor` without an app id would accept a
  commit status with that name from any app or token that can post statuses. Pinning it
  to `15368` accepts only GitHub Actions.

## Further reading
- [zizmor audit reference](https://docs.zizmor.sh/audits/)
- [Security hardening for GitHub Actions: using third-party actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)
- [GitHub changelog: Actions policy supports blocking and SHA pinning](https://github.blog/changelog/2025-08-15-github-actions-policy-now-supports-blocking-and-sha-pinning-actions/)
- [CISA: tj-actions/changed-files supply chain compromise (CVE-2025-30066)](https://www.cisa.gov/news-events/alerts/2025/03/18/supply-chain-compromise-third-party-tj-actionschanged-files-cve-2025-30066-and-reviewdogaction)
- [Available rules for rulesets: require status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-status-checks-to-pass-before-merging)
