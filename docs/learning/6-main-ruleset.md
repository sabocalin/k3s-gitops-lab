# 6 · Ruleset on `main`

> Issue: #6 · Phase 0 · Configured through the GitHub API (no PR: rulesets are repo settings, not files)

## What
A **repository ruleset** named `main` that applies to the default branch. It rejects
direct pushes, force pushes, branch deletion and unsigned commits, and requires every
change to arrive through a squash-merged pull request.

## Why
`main` is the source of truth for everything downstream. In Phase 4, ArgoCD deploys
whatever is on `main`, so protecting `main` is protecting the running cluster.

Without the ruleset:
- A mistaken `git push --force` could rewrite history that was already deployed.
- A change could skip CI entirely by being pushed straight to `main`.
- There is no record of *why* a change happened; a PR gives every change a description
  and a place for review comments (human or the AI reviewer from #57).

Alternatives considered:
- **Classic branch protection** — older mechanism, still works. Rulesets are the
  current one: several can apply at once, anyone with read access can see them, and
  they can target branches by pattern or by "default branch".
- **No protection, rely on discipline** — fine until the first tired evening.

## How it works
Rules are enforced **server-side, at push time**. When `git push` reaches GitHub, it
evaluates every active ruleset that targets the branch before accepting the update. If
any rule fails, GitHub rejects the push with error `GH013` and the branch is unchanged.
Nothing on your laptop is involved, so it cannot be bypassed by local git config.

Merging a PR is also a push to `main`, performed by GitHub; it passes because it
comes from a PR, is signed by GitHub, and is a squash (linear).

## Implementation
Ruleset `main` (id `23989149`), enforcement **Active**, bypass list **empty**
(no exceptions, not even the repo owner), target `~DEFAULT_BRANCH`.

| Rule | Why |
|---|---|
| Restrict deletions | `main` cannot be deleted. |
| Block force pushes | History that was deployed cannot be rewritten. |
| Require linear history | No merge commits; history reads as one change per PR. Pairs with squash-only. |
| Require signed commits | Every commit on `main` carries a verified signature. |
| Require a pull request, **0 approvals** | GitHub does not let you approve your own PR, so requiring 1 approval would block every merge on a solo repo. |
| Require conversation resolution | Open review comments block the merge until resolved. |
| Allowed merge method: squash | One commit per PR on `main`. |

Repository settings changed alongside:
- Only squash merging allowed (merge commits and rebase merging off).
- Squash commit title = PR title, message = PR body.
- Head branches deleted automatically after merge.

Not enabled yet: **required status checks**. You cannot require a check that has
never run; they get added once CI exists (#21 for `ruff`/`pytest`, #16 for `terraform plan`).

## Verification
- Positive: `gh api repos/sabocalin/k3s-gitops-lab/rules/branches/main` lists
  `deletion, non_fast_forward, required_linear_history, required_signatures, pull_request`.
- Negative control: an empty commit pushed directly to `main` was rejected:
  ```
  remote: error: GH013: Repository rule violations found for refs/heads/main.
  remote: - Changes must be made through a pull request.
  ! [remote rejected] HEAD -> main (push declined due to repository rule violations)
  ```
  Remote `main` stayed at its previous commit.

## Gotchas
- **The signature on `main` is GitHub's, not yours.** A squash merge creates a new
  commit, which GitHub signs with its own key. Your SSH signature lives on the branch
  commits, which are discarded after the merge. The rule still means something: only
  GitHub (via a PR) or your key can produce commits on `main`.
- **A leaked token can still create signed commits.** Commits created through the
  GitHub API are signed by GitHub. Signing proves "made through GitHub or with this
  key", not "made by this person"; tokens still need protecting.
- **Bot commits must be signed.** The Phase 4 image-tag bump must be committed through
  the GitHub API (signed automatically), not with a plain `git push` from a runner.
- **Empty bypass list includes you.** If a broken rule ever blocks everything, fix it
  in Settings → Rules; you can edit the ruleset even though you cannot bypass it.

## Further reading
- [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
- [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [About commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)
