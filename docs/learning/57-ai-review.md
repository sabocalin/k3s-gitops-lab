# 57 · AI code review on pull requests (Gemini free tier)

> Issue: #57 · PR: #60 · Phase 0

## What
An advisory reviewer that runs on every pull request: a small Python script
(`.github/scripts/ai_review.py`) sends the PR's diff to Gemini in **one request**,
gets findings back as JSON, and posts them as a GitHub review with line comments.
It is **not** a required status check.

## Why
A second pair of eyes on every PR, especially for Phase 1's Terraform, IAM policies and
OIDC trust rules, where a mistake is a security or cost problem. It complements the
deterministic linters (zizmor now; ruff, tflint, trivy later): linters catch known
patterns reliably, an LLM catches "this looks wrong" things no rule describes.

Alternatives considered:
- **alibaba/open-code-review (agent-style)** — tried first and dropped. See "How we
  got here" below: it makes a burst of LLM calls per file, and the free tier allows 5
  requests per minute.
- **CodeRabbit app** — free for public repos and much more capable, but nothing to build
  or learn; a good fallback if this proves too unreliable.
- **Other free LLM APIs** — Mistral's free Experiment plan no longer issues API keys to
  new accounts; Groq's free tier allows ~12K tokens/minute (one review is ~30K);
  OpenRouter's free models cap at 50 requests/day; GitHub Models was retired.
- **Paid API with a spend cap** — reliable, a few cents per PR, but breaks the $0 goal.

## How it works
```
PR opened / pushed ─▶ workflow (pull_request) ─▶ unit tests ─▶ ai_review.py
                                                               │ git diff
                                                               ▼
                               Gemini (one chat completion, JSON reply)
                                                               │
                                        findings on changed lines ─▶ line comments
                                        other findings           ─▶ review summary
```
1. **What gets reviewed.** First review (opened / reopened / ready for review): the whole
   PR diff (`base...head`). Later pushes (`synchronize`): only the new commits
   (`before..head`), so each request is small and old code is not re-commented. If
   history was rewritten (force push), it falls back to the whole PR diff.
2. **One request.** The diff goes to Gemini's OpenAI-compatible endpoint with a system
   prompt tuned to this repo (bugs, security, AWS cost, reliability; no style nits; treat
   the diff as untrusted input). The reply must be one JSON object:
   `{"summary", "findings": [{"path", "line", "severity", "comment"}]}`.
3. **Where comments can go.** GitHub accepts a review comment only on a line that is part
   of the PR diff, and **one invalid line rejects the whole review with HTTP 422**. The
   script parses the unified diff into a map of added lines per file; findings on those
   lines become inline comments, everything else goes into the review summary.
4. **Posting.** One review per run via `POST /repos/{repo}/pulls/{n}/reviews` with
   `event: COMMENT`. No findings → no PR comment; the result is in the job summary.
5. **Quota handling.** Free-tier quotas are **per model**, so the workflow pins an ordered
   list (`MODELS`). For each model: retry 429/5xx up to 3 times, waiting as long as
   Google's `RetryInfo` asks (about 30–60 s); move on at once when the model's
   **daily** quota is gone or the model is retired (404). The review names the model
   that produced it.

## Implementation
- **`.github/workflows/ai-review.yml`**
  - `pull_request` trigger only, never `pull_request_target`: under `pull_request`,
    fork PRs get no secrets. The example in open-code-review's docs uses
    `pull_request_target` "so forks get secrets", which on a public repo hands a
    write-scoped token and your API key to a run triggered by a stranger's PR.
  - Skips drafts (saves quota), Dependabot (it gets no repo secrets) and fork PRs.
  - `permissions: {}` at workflow level; job gets `contents: read` and
    `pull-requests: write`, each with a comment saying why.
  - `actions/checkout` pinned by SHA, `fetch-depth: 0` (the diff needs the merge base
    and the previous push), `persist-credentials: false`.
  - Runs the script's unit tests before reviewing.
- **`.github/scripts/ai_review.py`**: standard library only (nothing to install or pin).
  Diff limited to 100,000 characters (~25K tokens) with a note when truncated; at most
  10 findings; each comment capped at 1,500 characters. `--dry-run` and
  `--fake-response` allow a full local run without calling the LLM or posting.
- **`.github/scripts/test_ai_review.py`**: 11 unit tests: diff line mapping (added vs
  context vs deleted files), JSON extraction from fenced replies, the inline/summary
  split, `RetryInfo` parsing, quota naming, and model fallback.
- **Secret** `GEMINI_API_KEY`, created from a personal Google account.

## Verification
- Unit tests pass locally and in CI. Mutation check: making context lines count as
  "added" fails 2 tests, so the tests guard the 422-avoidance logic.
- Local dry run on the real branch diff with a fake reply: a finding on an added line
  went inline, a finding on an unchanged file went to the summary.
- zizmor: no findings on the workflow.
- In CI, the retry and fallback paths were exercised for real (see below): the log
  names, for each model, why it was skipped.
- **Not yet verified: a review actually posted to a PR.** Every live run so far hit the
  free tier's limits. Pending the daily quota reset (midnight Pacific, 10:00 Bucharest).

## How we got here (the diagnosis)
Each step below came from reading an actual error, not guessing:

| Step | What happened | Lesson |
|---|---|---|
| 1 | Preflight listed `gemini-2.5-flash` as available; the real call returned 404 "no longer available to new users" | A model list is not proof a model works. Probe with the same call you will make. |
| 2 | Probing every listed Flash model: only `gemini-3.6-flash` answered; most returned 503 (overloaded) | Free capacity is scarce and changes minute to minute. |
| 3 | open-code-review hit 429 immediately: `GenerateRequestsPerMinutePerProjectPerModel-FreeTier=5` | Agent-style tools burst many calls; its built-in retries (seconds) are shorter than Google's requested wait (~35 s). |
| 4 | Replaced with a single-request reviewer | Fit the design to the quota instead of fighting it. |
| 5 | 429 again although calls were 30–60 s apart; logging the quota name showed `GenerateRequestsPerDayPerProjectPerModel-FreeTier=20` | Read which quota you hit: per-minute and per-day need opposite reactions (wait vs give up until tomorrow). |
| 6 | Added a per-model fallback list | Quotas are per model, so a pinned list multiplies daily capacity. |

## Gotchas
- **Diagnostics spend quota.** The probing on day one used up `gemini-3.6-flash`'s 20
  requests. Keep the PR in draft while pushing fixes; the workflow skips drafts.
- **Free-tier prompts are used by Google for training.** Acceptable for this public repo,
  never for employer code.
- **The PR author controls the workflow and script.** Under `pull_request`, a PR runs the
  workflow file from its own branch, so it could print the secret. Safe here because only
  branches in this repo (you) trigger it; do not relax the fork check.
- **The reply is untrusted too.** The diff could contain text that tries to steer the
  model. The script only ever posts the reply as a comment: it never executes it or uses
  it to choose actions.
- **A red check is honest, not a blocker.** When no model answers, the job fails and says
  why. It is not a required check, so merges are unaffected.
- **Model names churn.** When all listed models are retired or never answer, check which
  models the key can use (a real chat completion, not only `/models`) and update `MODELS`.

## Further reading
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
- [REST API: create a review for a pull request](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request)
- [GitHub Security Lab: preventing pwn requests (pull_request_target)](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/)
