# 3 · Dependabot version updates

> Issue: #3 · PR: #56 · Phase 0

## What
Dependabot is a GitHub-hosted bot that watches the versions this repo pins and opens
pull requests to bump them. `.github/dependabot.yml` configures its **version updates**
for four ecosystems: GitHub Actions, pip, Docker and Terraform.

## Why
The project pins everything: actions by commit SHA, base images by digest, providers
by version. Pinning makes builds reproducible, but a pin never updates itself; left
alone, pins go stale and quietly accumulate known vulnerabilities.

Dependabot turns "keep pins fresh" into ordinary PRs, so every bump goes through the
same gates as your own code: CI, the Trivy scan, the AI reviewer and the `main` ruleset.
It is also what makes SHA-pinned actions (#4) practical: nobody wants to look up
40-character SHAs by hand.

Alternatives considered:
- **Renovate** — more powerful and configurable, but a third-party app with its own
  config language. Dependabot is built in and enough for this repo.
- **Manual updates** — does not happen in practice.

## How it works
Dependabot does two separate jobs:

| Job | Trigger | Configured in |
|---|---|---|
| **Security updates** | A published vulnerability (GitHub Advisory Database) affects a version you use | Repo settings (already on) |
| **Version updates** | Any new release, checked on a schedule | `.github/dependabot.yml` |

On each scheduled run, for each `updates` entry, Dependabot:
1. Reads the manifests in that directory (e.g. `requirements.txt`, `Dockerfile`,
   `.github/workflows/*.yml`, `*.tf`).
2. Asks the ecosystem's registry (PyPI, Docker Hub/GHCR, GitHub releases, Terraform
   Registry) for newer versions.
3. Applies the rules: cooldown, groups, ignore lists.
4. Opens or updates one PR per group (or per dependency when ungrouped), with release
   notes and a compatibility score in the description.

A push that changes `dependabot.yml` on the default branch triggers a run immediately.

## Implementation
One file: `.github/dependabot.yml`.

| Ecosystem | Directory | Grouping |
|---|---|---|
| `github-actions` | `/` (scans `.github/workflows` and composite actions) | All actions in one PR |
| `pip` | `/app` | Minor + patch in one PR; each major bump separately |
| `docker` | `/app` | One PR per base image |
| `terraform` | `/terraform/bootstrap`, `/terraform/main` | All in one PR |

Non-default settings:
- **Schedule** weekly, Monday 06:00 Europe/Bucharest: one predictable batch a week
  instead of a trickle of PRs.
- **`cooldown: default-days: 3`**: a new release is only proposed once it is 3 days old.
  Hijacked releases (a maintainer account compromised, a malicious version published)
  are usually noticed and yanked within hours to days; waiting avoids pulling one in.
  Security updates are not delayed by the cooldown.
- **Groups** cut PR noise. Majors stay separate for pip because they are the ones that
  break things and deserve their own review.
- **`commit-message.prefix: chore(deps)`** matches the repo's conventional-commit style.
- `terraform` was added beyond the issue's scope because Phase 1 pins provider versions.

## Verification
- Positive: `check-jsonschema --builtin-schema vendor.dependabot .github/dependabot.yml`
  → `ok -- validation done`.
- Negative control: the same file with `default-days` misspelled as `default-daze`
  fails validation with `Additional properties are not allowed`.
- After merge: 0 Dependabot PRs and 0 alerts, as expected with no dependencies yet.
  The run itself is visible in the UI under Insights → Dependency graph → Dependabot.

## Gotchas
- **Missing directories report errors.** `pip`, `docker` and `terraform` show
  "dependency file not found" until Phase 1/2 create `app/` and `terraform/`. Expected.
- **Dependabot PRs do not get repository secrets.** They run with a read-only token and
  only "Dependabot secrets". Any workflow needing a secret (the AI reviewer, #57) must
  skip them or it fails on every Dependabot PR.
- **YAML anchors are avoided.** GitHub does not document anchor support in
  `dependabot.yml`, so the schedule block is repeated in full.
- **Folder layout is now a contract.** If code lands somewhere other than `app/` or
  `terraform/{bootstrap,main}`, update the directories here.
- **If Phase 2 uses `uv`**, switch the pip entry to `package-ecosystem: "uv"`.

## Further reading
- [Dependabot options reference](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference)
- [About Dependabot version updates](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/about-dependabot-version-updates)
- [About Dependabot security updates](https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/about-dependabot-security-updates)
