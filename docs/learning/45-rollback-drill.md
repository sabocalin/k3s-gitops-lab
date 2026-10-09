# 45 · Rollback drill: git revert the image bump

> Issue: #45 (4.8) · PR: #116 (the revert), this PR (the results) · Phase 4

## What
A rehearsed rollback. The bot's bump commit from #44 (`a03b754`, image `307ec672…`,
version `b7f1bda`) was undone with `git revert`, through an ordinary PR. Both namespaces
went back to the previous build (`9186280a…`, version `c08b42b`), and each step was timed,
from opening the PR to the last pod ready.

## Why
A bad build will ship one day, and the way back should be known and timed before then,
not worked out during an incident. In this setup git is the desired state of both
namespaces (#44): a rollback that doesn't change git either gets undone (gitops) or
silently disagrees with git (push).

Alternatives considered:
- **`kubectl rollout undo`**: instant, but in `gitops` Argo CD's self-heal puts the new
  image back within seconds (measured below). In `push` it would hold until the next
  deploy, with git saying otherwise.
- **`argocd app rollback`**: redeploys an earlier synced revision, but Argo CD refuses it
  while automated sync is on. Turning sync off during an incident adds a step and a state
  to remember to undo.
- **Edit the digest back by hand**: the same diff as the revert, but the history no longer
  says which change was undone or why.
- **Fix forward** (a new commit that fixes the bug): often right, but slower (build,
  scan, sign, bump) and riskier under pressure. A revert redeploys a build that already
  ran.

## How it works
```
git revert a03b754 ─▶ PR #116 (checks) ─▶ merge (9884d1b): k8s/components/lab-api-image
   │                                      digest 307ec672… → 9186280a…
   ├─▶ deploy-push.yml (paths: k8s/components/**) ─▶ kubectl apply ─▶ push
   └─▶ Argo CD: next poll of main ─▶ sync ─▶ gitops
no image.yml run: nothing under app/ changed, the old image is already signed in GHCR
```
- **A revert is a normal change.** It goes through the same PR, checks and signed-commit
  rules (#6) as anything else, and both deploy paths treat it like any bump.
- **Why the rollout itself is fast.** A Deployment's ReplicaSets are named after a hash
  of the pod template. Going back to the previous image recreates the previous template,
  so Kubernetes scales the old ReplicaSet (`lab-api-59f5d75b88`, created the day before)
  back up instead of making a new one. The image was still cached on the node: no pull.
- **The revert holds until the next build.** The next merge under `app/` builds a new
  image, and the bot bumps both namespaces to it. That's the right default once the bug
  is fixed, but it means "rolled back" isn't a frozen state.

## Implementation
- PR #116: `git revert a03b754`, one line in `k8s/components/lab-api-image`. No code
  or workflow changes were needed: #44's shared pin already made one commit move both
  namespaces.
- This PR: the note.

## Verification
The same laptop poller as #44 read, every 2 s, the version `/` returns in each namespace:
- `push`: the public URL;
- `gitops`: the API server's service proxy.

Timeline (UTC), from opening PR #116 at **09:35:54**:

| Time | From PR open | From merge | Event |
|---|---|---|---|
| 09:35:54 | 0:00 | | revert PR #116 opened |
| 09:36:33 | 0:39 | | all 6 checks green |
| 09:40:42 | 4:48 | 0:00 | merged (`9884d1b`); waiting for the human merge took 4 min 09 s |
| 09:40:45 | 4:51 | 0:03 | deploy-push starts |
| 09:41:33 | 5:39 | 0:51 | first `push` response from `c08b42b` |
| 09:41:47 | **5:53** | **1:05** | **push recovered**: 3/3 pods on `9186280a…`, public `/health` 200 |
| 09:43:37 | 7:43 | 2:55 | Argo CD compares, sees `9884d1b`, syncs (automated) |
| 09:43:51 | 7:57 | 3:09 | first `gitops` response from `c08b42b` |
| 09:44:03 | **8:09** | **3:21** | **gitops recovered**: 3/3 pods on `9186280a…` |

- **Done when:** both namespaces run the previous version, `c08b42b`, seen from the
  consumer side. **Time to recover: 8 min 09 s** from deciding to roll back, and 3 min
  21 s from the merge.
- The poller logged no failed request during either rollout.
- CI is green on `9884d1b` (k8s, deploy-push, app-ci, zizmor, terraform-lint), and no
  image build ran.

Negative control, run before the revert: `kubectl rollout undo deploy/lab-api -n gitops`
switched the Deployment to `9186280a…` for about 1 s. Argo CD's self-heal (an automated
sync at 09:35:29) set `307ec672…` back, and all 3 pods stayed on it. An imperative
rollback doesn't stick in the pull model.

Compared with the roll-forward in #44, from each merge to both namespaces done:

| | #44 roll forward | #45 roll back |
|---|---|---|
| Build + bot PR | 2 min 24 s | none |
| push | 3 min 27 s | 1 min 05 s |
| gitops | 8 min 08 s | 3 min 21 s |

## Gotchas
- **The human merge was the largest part of the push recovery time**: 4 min 09 s of 5 min
  53 s. For a real incident, the people who can approve and merge a revert need to be
  reachable. The checks themselves took 39 s.
- **Gitops recovery depends on where the poll falls.** Here Argo CD compared 2 min 55 s
  after the merge. In #44 it took 5 min 18 s, because a compare just before the merge
  cached the old commit. Two runs so far: 2 min 55 s and 5 min 18 s.
- **The pod-template hash makes rollbacks cheap**, but only while the old ReplicaSet is
  kept (`revisionHistoryLimit: 5` in `k8s/base/deployment.yaml`) and the image is still on the node. A rollback
  further back pulls the image again and creates a new ReplicaSet.
- **The bot's commit headline still says `chore(gitops)`** although it now bumps both
  namespaces (#44). Cosmetic; to fix the next time `scripts/bump-image.sh` changes.

## Further reading
- [Argo CD: rollback (and why automated sync blocks it)](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_rollback/)
- [Kubernetes: rolling back a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment)
- [git revert](https://git-scm.com/docs/git-revert)
