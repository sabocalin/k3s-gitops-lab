# k3s-gitops-lab — working rules for Claude

This is a learning project. For EVERY task, teaching is part of the deliverable.
This overrides terse/short-answer preferences inside this repo only.

## Per task

1. **Before implementing:** explain what the component is, why the project needs it,
   and the alternatives considered (one line each, with why not).
2. **While implementing:** explain how it works — the mechanism, not just the config.
   Call out every non-default setting and why it was chosen.
3. **After implementing:** show how it was verified, including a negative control
   (prove the thing fails when it should, not only that it passes).
4. **Write it down** in `docs/learning/<issue-number>-<slug>.md` using the sections in
   [`docs/learning/_template.md`](docs/learning/_template.md), add a row to
   [`docs/learning/README.md`](docs/learning/README.md), and link the note from the PR description.

## Conventions

- One branch per issue: `gh issue develop <n> --checkout`. PR body contains `Closes #<n>`.
- Signed commits, squash merge only; `main` is protected by a ruleset (no direct push).
- $0 budget: check the README "Never create" list before adding any AWS resource.
- Pin everything: actions by commit SHA, images by digest, tools by exact version.
- Personal GitHub account only. Use `GH_TOKEN=$(gh auth token --user sabocalin) gh ...`
  so the global gh account is never switched.
- Never reuse anything from this repo's free-tier AI setup on employer code.
