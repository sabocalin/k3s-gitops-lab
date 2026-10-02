# 21 · App CI: ruff and pytest on every PR

> Issue: #21 (2.3) · Phase 2

## What
The `app-ci` workflow runs two jobs on every PR and on `main`: **ruff** (lint and
format) and **pytest**. Both are required status checks in the `main` ruleset, next to
`zizmor` and `terraform-lint`.

## Why
`make test` protects only when someone remembers to run it. A required check makes
"tests pass and the style is clean" a property of `main` itself.

Alternatives considered:
- **One combined job** — a lint failure would hide the test result; two jobs give two
  separate signals and run in parallel.
- **`actions/setup-python` + pip** — ignores `uv.lock`, so CI could test other versions
  than the image ships.
- **pre-commit hooks** — local only; cannot be the gate.

## How it works
```
PR ─▶ app-ci ──┬─ ruff:   checkout ─▶ setup-uv (uv 0.12.8, SHA-256 checked)
               │          ─▶ uv sync --locked ─▶ ruff check --output-format=github
               │                              ─▶ ruff format --check --diff
               └─ pytest: checkout ─▶ setup-uv ─▶ uv sync --locked ─▶ pytest
```
- **`uv sync --locked`** fails when `pyproject.toml` and `uv.lock` disagree, so a pin changed
  without `uv lock` never reaches `main`. Later steps use `--frozen`: the lock was just checked.
- **The uv binary is pinned by hash.** setup-uv's `checksum` input refuses any download that
  does not match. The hash matched my own download, and the release is attested by
  `astral-sh/uv`'s release workflow (`gh attestation verify`).
- **Python** comes from `app/.python-version` (3.13): uv downloads CPython 3.13.15.
- **`--output-format=github`** turns ruff findings into annotations on the PR diff.
- **`timeout-minutes: 10`**: a hung test (the #19 helper bug) fails in 10 minutes instead of
  holding a runner for the 6-hour default.
- **Every PR, not path-filtered:** a required check that never reports blocks the merge.

## Implementation
- `.github/workflows/app-ci.yml`: `permissions: {}` at the top, `contents: read` per job,
  `persist-credentials: false`, `enable-cache: false` (a few small wheels; no cache to
  poison), actions pinned by SHA.
- Ruleset `main`: required checks `zizmor, terraform-lint, ruff, pytest`.

## Verification
| Run | Commit | Result |
|---|---|---|
| 37000906984 | the workflow | ruff ✓, pytest ✓ (`7 passed`) |
| **37000964497** | **unused import + `/health` returns `"OK"`** | **ruff ✗** `F401 'json' imported but unused` (as an annotation); **pytest ✗** `assert {'status': 'OK'} == {'status': 'ok'}`, 1 failed / 6 passed |
| **37001027450** | **pin changed in pyproject.toml, not re-locked** | **both ✗** at `uv sync --locked`: `The lockfile at uv.lock needs to be updated, but --locked was provided.` |
| 37001080328 | both reverted (`app/` identical to the first commit) | ruff ✓, pytest ✓ |
| Ruleset | | required: `zizmor, terraform-lint, ruff, pytest`; enforcement, conditions, bypass and other rules unchanged |

## Gotchas
- **Mergeability is recomputed lazily.** Right after the ruleset change, the PR showed
  `BLOCKED` with every check green. A few seconds later: `CLEAN`. Re-query before chasing
  a phantom blocker.
- **Check names are job names.** The ruleset matches the job's `name:` (`ruff`, `pytest`),
  not the workflow name. Renaming a job silently creates a new check, and the old
  required one never reports again.

## Further reading
- [astral-sh/setup-uv](https://github.com/astral-sh/setup-uv)
- [uv: `--locked` vs `--frozen`](https://docs.astral.sh/uv/concepts/projects/sync/#checking-if-the-lockfile-is-up-to-date)
- [ruff output formats](https://docs.astral.sh/ruff/settings/#output-format)
- [GitHub: required status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-status-checks-to-pass-before-merging)
