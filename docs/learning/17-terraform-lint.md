# 17 · Terraform checks in CI: fmt, validate, tflint, trivy

> Issue: #17 (1.10) · Phase 1

## What
Every PR runs `scripts/lint-terraform.sh` (also `make lint` on the laptop): `terraform
fmt -check`, `terraform validate` for each stack, **tflint** with the AWS ruleset, and
**trivy config**. Any failure fails the `terraform-lint` check, which the `main` ruleset requires before merging (next to `zizmor`).

## Why
`terraform plan` says *what* will change, not whether the change is wrong or unsafe.
These checks catch it in the PR, before anyone applies:

| Tool | Catches | Example |
|---|---|---|
| `fmt` / `validate` | formatting, syntax, broken references | a renamed resource still referenced |
| tflint (+ `aws` ruleset) | valid HCL that is wrong for AWS; hygiene | `instance_type = "t4g.smal"`, undocumented outputs |
| trivy config | security misconfiguration | port 22 open to `0.0.0.0/0`, unencrypted disk, IMDSv1 |

Alternatives considered:
- **checkov** — similar rules to trivy; Python with a large dependency tree.
- **The tools' GitHub Actions** (setup-tflint, trivy-action) — an extra trust dependency;
  trivy-action's tags were hijacked in March 2026 (Trivy advisory "Trivy ecosystem supply
  chain temporarily compromised", 2026-03-21).
- **pre-commit hooks only** — run only where installed; CI is the gate that cannot be skipped.
- **Plan in CI with the plan role (#16)** — needs AWS and is a different job; static
  checks first, a plan job can come later.

## How it works
```
PR ─▶ terraform-lint job (no AWS credentials, contents: read)
       └─ scripts/lint-terraform.sh
            ├─ fetch tflint 0.64.0, trivy 0.74.0 ── SHA-256 pinned in the script, else refuse
            ├─ terraform fmt -check -recursive terraform/
            ├─ for each stack: init -backend=false (own TF_DATA_DIR) + validate
            ├─ tflint --recursive  (.tflint.hcl: terraform "all" preset + aws ruleset 0.49.0)
            └─ trivy config --skip-check-update --exit-code 1 terraform/
```
- **Pinned by hash, not by tag.** A tag or release asset can be moved; a SHA-256 in the
  repo cannot. The hashes were computed from the downloads and matched the published
  checksum files. Trivy's archive additionally has a GitHub attestation
  (`gh attestation verify`): built by `aquasecurity/trivy`'s release workflow at
  `refs/tags/v0.74.0`. tflint publishes none (a cosign signature on its checksums file instead).
- **The tflint AWS plugin** is downloaded by `tflint --init` and its signature checked
  against the key built into tflint.
- **`--skip-check-update`**: trivy uses the rules built into the pinned binary rather than
  the latest rules bundle, so results change only when we bump the version.
- **No AWS, enforced.** The script points `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` at
  `/dev/null` and unsets credential variables. `init -backend=false` runs in a separate data
  directory, so a stack already set up for `terraform plan` on the laptop is never touched.
- **All checks run** even after one fails; the summary lists every failure.

## Implementation
- `scripts/lint-terraform.sh`, `.tflint.hcl`, `Makefile` (`make lint`),
  `.github/workflows/terraform-lint.yml` (`hashicorp/setup-terraform` pinned by SHA,
  Terraform 1.16.4, `terraform_wrapper: false` for plain exit codes).
- First run found 21 issues. **Fixed:** 12 missing variable/output descriptions.
  **Disabled:** `terraform_standard_module_structure` (meant for reusable modules; these
  are root stacks split by concern). **Accepted with an inline reason**
  (`# trivy:ignore:<id>` right above the resource):

| Trivy | Severity | Why accepted |
|---|---|---|
| AWS-0104 egress to `0.0.0.0/0` | CRITICAL | apt, GHCR, Tailscale, Let's Encrypt, Grafana Cloud: changing addresses; a port list would still be `0.0.0.0/0` |
| AWS-0164 subnet assigns public IPs (×3) | HIGH | the design: no NAT gateway (~$33/month); inbound limited to 80/443 |
| AWS-0132 no customer-managed KMS key | HIGH | $1/month, README "Never create"; SSE-S3 encrypts at rest |
| AWS-0178 no VPC flow logs | MEDIUM | billed per GB; enable temporarily when debugging |
| AWS-0089 no bucket access logging | LOW | needs a second bucket; private, versioned, CloudTrail covers access |

- `terraform plan` of bootstrap and platform after the edits: **no changes**. The instance
  stack shows only output drift (the stopped node has no public IP), the same on `main`.

## Verification
| Check | Result |
|---|---|
| `make lint` locally | `all Terraform checks passed` |
| **Negative: wrong tool hash** | `tflint 0.64.0: SHA-256 mismatch ... refusing to run it`; nothing extracted |
| **Negative: no AWS configuration at all** (`env -i`) | still passes: the checks need no AWS |
| CI on the PR, good commit (run 36869763396) | passed |
| **Negative: deliberately bad commit** `85f78c1` (run 36869872671) | **failed** on all three: fmt (`description = "SSH"` misaligned); tflint `"t4g.smal" is an invalid value as instance_type (aws_instance_invalid_type)`, traced from the variable default into `aws_instance`; trivy `AWS-0107 (HIGH): Security group rule allows unrestricted ingress from any IP address` |
| Revert (run 36870001613) | passed; tree identical to the good commit |
| Required check | ruleset on `main`: required checks now `zizmor, terraform-lint`; enforcement, conditions, bypass list and other rules unchanged |

## Gotchas
- **`init -backend=false` still loads an existing backend.** In a stack already initialized
  for S3, it tried to authenticate. With `AWS_PROFILE` unset, that meant this laptop's
  `default` profile (an employer account). It failed only because that session had
  expired. Hence the separate `TF_DATA_DIR` and the forced empty AWS config.
- **A `trivy:ignore` comment covers the next line only.** With the ignore on the first line
  of a multi-line comment, it applied to the next comment line and the finding stayed.
  Keep the ignore directly above the resource, reasons above it.
- **Trivy flags on-purpose design choices.** The value is in deciding each one once, in
  writing, next to the code; a new finding then stands out.

## Further reading
- [tflint](https://github.com/terraform-linters/tflint) · [AWS ruleset rules](https://github.com/terraform-linters/tflint-ruleset-aws/blob/master/docs/rules/README.md)
- [Trivy: misconfiguration scanning](https://trivy.dev/latest/docs/scanner/misconfiguration/) · [ignoring findings inline](https://trivy.dev/latest/docs/configuration/filtering/#by-inline-comments)
- [Trivy advisory, 2026-03-21](https://github.com/aquasecurity/trivy/security/advisories)
- [GitHub artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
