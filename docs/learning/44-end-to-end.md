# 44 · End to end: one commit, both namespaces

> Issue: #44 (4.7) · PR: #113 (the change and the run), this PR (the results) · Phase 4

## What
One commit to `main` that touches the app ends with both namespaces serving the image
built from that commit:
- `push`, through GitHub Actions and `kubectl apply` (#39);
- `gitops`, through Argo CD pulling from git (#42).

The run here was timed from the merge to the last new pod being ready, from the outside:
the version that `/` returns is the git commit the image was built from.

## Why
Every piece had been tested on its own: build and sign (#22–#25), the bot bump (#41), push
deploy (#39), Argo CD sync (#42). This test is about the hand-offs between them.

It found one broken hand-off before the run even started: the push overlay pinned its own
image digest inline, and only the gitops overlay was bumped. `push` had been stuck on an
older build (`1b612533…`, version `3e9dd8c`) since #41.

Alternatives considered (for the fix):
- **deploy-push sets the image at deploy time** from the build's output (`kustomize edit
  set image` in the job): no bot commit needed for push. But then git doesn't say what
  `push` runs, and a re-run of an old deploy would silently roll forward or back.
- **The bot edits two files, one per overlay**: same effect as a shared Component, but two
  pins that can drift apart by hand.
- **A shared Component** (chosen): one pin, one line per bump, both overlays include it.

## How it works
```
merge app change (b7f1bda) ─▶ image.yml: publish (build, scan, smoke, push, sign)
                              └▶ image-bump: verify signature ─▶ bot PR #114: one line in
                                 k8s/components/lab-api-image ─▶ checks ─▶ auto-merge (a03b754)
a03b754 on main ─┬▶ deploy-push.yml (paths: k8s/components/**): kubectl apply ─▶ push
                 └▶ Argo CD: next poll of main sees a03b754 ─▶ sync ─▶ gitops
```
- **Two commits, one trigger.** The app commit builds the image; the bot's commit pins it.
  Both namespaces deploy the bot's commit. "One commit" in the issue is the human one:
  after it, nothing else is done by hand.
- **Push reacts to the merge event**: GitHub starts deploy-push seconds after the bot's
  merge. **Gitops waits for a poll**: Argo CD checks `main` every 3 minutes plus jitter,
  and the repo-server caches which commit `main` resolves to.

## Implementation
(PR #113)
- `k8s/components/lab-api-image/` (moved from `k8s/overlays/gitops/image/`): the image
  Component, now included by both overlays. The push overlay's inline `images:` went.
  - The gitops render was identical before and after.
  - Push moved from `1b612533…` to `9186280a…`, the build gitops already ran, on the
    merge itself.
- `scripts/bump-image.sh` (renamed from `bump-gitops-image.sh`): edits the shared
  Component. The branch prefix is now `bot/image-` and the job is `image-bump`.
  `ai-review.yml` follows the new prefix.
- `.github/workflows/deploy-push.yml`: paths gain `k8s/components/**`, so a bump starts a
  push deploy.
- `app/src/lab_api/main.py`: one docstring line (`/`'s version is the image's commit).
  Any change under `app/` starts a build; this one was the test commit.

## Verification
A laptop poller recorded, every 2 s, the version and pod that `/` returns in each
namespace:
- `push`: the public URL, through Traefik;
- `gitops`: the API server's service proxy, since `gitops` has no Ingress.

Timeline (UTC), from the merge of #113 (`b7f1bda`) at **09:11:13**:

| Time | +m:ss | Event |
|---|---|---|
| 09:11:16 | 0:03 | image.yml starts. deploy-push also starts, for #113's own push-overlay change: push moves to `9186280a…` (version `c08b42b`) by 09:12:27 |
| 09:12:24 | 1:11 | image built, scanned, pushed and signed: `sha256:307ec672…` |
| 09:12:40 | 1:27 | bot PR #114 opened; its commit is signed (Verified) and changes one file |
| 09:13:37 | 2:24 | #114 auto-merged (`a03b754`) after 57 s of checks |
| 09:13:41 | 2:28 | deploy-push starts for `a03b754` |
| 09:14:30 | 3:17 | first `push` response from `b7f1bda` |
| 09:14:40 | **3:27** | **push done**: rollout complete, 3/3 pods on `307ec672…`, public `/health` 200 |
| 09:14:58 | 3:45 | Argo CD compares `lab-api-gitops`: still the old commit (see Gotchas) |
| 09:18:55 | 7:42 | Argo CD compares again, sees `a03b754`, syncs (automated) |
| 09:19:11 | 7:58 | first `gitops` response from `b7f1bda` |
| 09:19:21 | **8:08** | **gitops done**: rollout complete, 3/3 pods on `307ec672…` |

- **Done when:** both namespaces run `b7f1bda` (image `sha256:307ec672…`), seen from the
  consumer side. Total: **8 min 08 s**. Push alone took 3 min 27 s.
- During both rollouts the poller logged no failed request: no `ERR` line at 2 s
  intervals. Old and new versions alternated in `push` for 13 s while pods rolled.
- CI is green on both commits (`b7f1bda`: app-ci, image, k8s, deploy-push, zizmor,
  terraform-lint; `a03b754`: the same without image), and the bot merge started no new
  build.

Negative control: before this change. #41's bot merge (`4db8663`) moved only `gitops`;
`push` stayed on `3e9dd8c` (the poller's baseline at 09:01:47 still showed it). A commit
could not reach both namespaces until the pin was shared.

## Gotchas
- **Argo CD missed the commit on its first look.** The bot merged at 09:13:37. The root
  app had compared at 09:13:35, two seconds earlier, resolving `main` to the old commit.
  `lab-api-gitops` compared at 09:14:58 and still saw that commit. The likely reason is
  the repo-server's resolved-revision cache (3 min by default), shared by every app
  watching the same repository and branch. It's an inference from the timestamps, not
  verified. Either way a commit can wait longer than one poll interval. A webhook, or
  `argocd app get --refresh`, would cut this; core has no webhook endpoint (#42).
- **The 3-minute poll dominates the gitops path**: 5 min 18 s waiting, 26 s doing. On
  the push side, deploy-push took 63 s from start to finish.
- **Mixed versions during a rollout are normal**: `maxSurge: 1, maxUnavailable: 0` (#28)
  replaces pods one at a time, so for about 15 s both versions answer.
- **Renaming a CI job is safe only if it isn't a required check.** `gitops-bump` →
  `image-bump` wasn't one; a required check that disappears blocks every PR.
- **The API server's service proxy reached pods despite default-deny.** The API server
  connects from the node itself, and K3s' NetworkPolicy controller apparently doesn't
  filter that traffic (observed, not looked up). Only callers with `services/proxy` RBAC
  (admins) can use it. Useful for measuring, and worth knowing.

## Further reading
- [Argo CD: reconciliation timeout and jitter (argocd-cm `timeout.reconciliation`)](https://argo-cd.readthedocs.io/en/stable/operator-manual/argocd-cm-yaml/)
- [Argo CD: git webhook configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/)
- [Kustomize components](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
- [Kubernetes: API server proxy](https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster-services/#manually-constructing-apiserver-proxy-urls)
