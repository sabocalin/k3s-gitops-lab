#!/bin/sh
# #41, #44: point both deploy paths at a newly published image, through a PR. Run by
# image.yml after image-publish, with a GitHub App token (GH_TOKEN), on a checkout of the
# latest main.
#
#   scripts/bump-image.sh <image>@sha256:<digest>
#
# 1. `kustomize edit set image` in k8s/components/lab-api-image (a Component only this
#    script edits, included by both k8s/overlays/push and k8s/overlays/gitops), then
#    render + check everything (render-k8s.sh).
# 2. A branch bot/image-<digest prefix> from main, and ONE commit on it made through
#    the GraphQL API (createCommitOnBranch): GitHub signs it, so it shows as Verified. A
#    plain `git push` from the runner would be unsigned.
# 3. Older open bump PRs are closed as superseded; the new PR gets auto-merge (squash), so
#    it merges by itself once the required checks pass. main's ruleset is unchanged.
set -eu

ref=${1:?usage: $0 <image>@sha256:<digest>}
: "${GH_TOKEN:?GH_TOKEN (GitHub App token) required}"
: "${GITHUB_REPOSITORY:?}"
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/tools.sh
. scripts/lib/tools.sh
KUSTOMIZE=$(fetch_tool kustomize)

case $ref in
  *@sha256:*) ;;
  *) echo "bump: '$ref' is not <image>@sha256:<digest>" >&2; exit 1 ;;
esac
digest=${ref#*@}
short=$(printf '%s' "${digest#sha256:}" | cut -c1-12)
dir=k8s/components/lab-api-image
file=$dir/kustomization.yaml
repo=$GITHUB_REPOSITORY
branch=bot/image-$short

(cd "$dir" && "$KUSTOMIZE" edit set image "$ref")
if git diff --quiet -- "$file"; then
  echo "bump: main already pins $digest; nothing to do"
  exit 0
fi
git --no-pager diff -- "$file"
# The PR's checks run this too; failing here avoids opening a PR that cannot merge.
scripts/render-k8s.sh "$(mktemp -d)" >/dev/null

# A re-run for the same image: its branch (and PR) already exist.
if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  echo "bump: $branch already exists (re-run of the same image); nothing to do"
  exit 0
fi

# Branch from the CURRENT main (the API's view, not this checkout's), then one commit on it.
main_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main_sha" >/dev/null
body=$(printf 'Image: %s\nBuilt and signed by image.yml from %s (run %s).\nVerified with scripts/verify-image.sh before this commit.' \
  "$ref" "${GITHUB_SHA:-?}" "${GITHUB_RUN_ID:-?}")
jq -n --arg repo "$repo" --arg branch "$branch" --arg head "$main_sha" \
  --arg path "$file" --arg contents "$(base64 <"$file" | tr -d '\n')" \
  --arg headline "chore(gitops): deploy lab-api $short" --arg body "$body" \
  '{query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }",
    variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      expectedHeadOid: $head,
      message: {headline: $headline, body: $body},
      fileChanges: {additions: [{path: $path, contents: $contents}]}}}}' >"$RUNNER_TEMP/commit.json"
commit=$(gh api graphql --input "$RUNNER_TEMP/commit.json" --jq .data.createCommitOnBranch.commit.oid)
echo "bump: commit $commit on $branch"

pr=$(gh pr create --repo "$repo" --base main --head "$branch" \
  --title "chore(gitops): deploy lab-api $short" \
  --body "$(printf '%s\n\nOpened by %s (#41). Merges itself once the required checks pass; then deploy-push applies the push namespace (#39) and Argo CD syncs the gitops namespace (#42).' "$body" "image.yml")")
echo "bump: $pr"

# Superseded: an older bump that has not merged yet would otherwise conflict, or worse,
# merge after this one and roll both namespaces back to an older build.
gh pr list --repo "$repo" --state open --json number,headRefName --jq \
  ".[] | select(.headRefName | startswith(\"bot/image-\")) | select(.headRefName != \"$branch\") | .number" |
  while read -r old; do
    gh pr close "$old" --repo "$repo" --delete-branch --comment "Superseded by $pr."
    echo "bump: closed superseded #$old"
  done

gh pr merge "$pr" --repo "$repo" --auto --squash
echo "bump: auto-merge enabled on $pr"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### image bump\n\n| | |\n|---|---|\n| Image | `%s` |\n| PR | %s |\n| Commit | `%s` (signed by GitHub) |\n' \
    "$ref" "$pr" "$commit" >>"$GITHUB_STEP_SUMMARY"
fi
