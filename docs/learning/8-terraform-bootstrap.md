# 8 · Terraform bootstrap stack (state bucket, budget, contacts)

> Issues: #8 (1.1) and #2 (0.1) · PR: see issue · Phase 1 (and the last task of Phase 0)

## What
`terraform/bootstrap/` is the first Terraform stack and the only one with a special job:
it creates the **S3 bucket that stores the state of every stack**, including its own.
It also creates the **$5 monthly budget alert** (#2) and points AWS's **alternate
contacts** (billing, operations, security) at a monitored mailbox.

It is part of the permanent layer: it is never destroyed by `make down` (#61).

## Why
Terraform records what it manages in a *state* file. On a laptop that file is one
`rm` or a lost disk away from Terraform forgetting every resource it created. In S3,
with versioning, it is durable, shared by local runs and CI (#16), and locked so two
runs cannot corrupt it.

The budget exists because the account is on the **paid plan with no credits**: nothing
caps spending, so something has to raise its hand. The alternate contacts exist because
AWS sends abuse, security and billing notices to the root email, and that address is
not monitored.

Alternatives considered:
- **Terraform Cloud / HCP for state** — free tier exists, but it adds a third-party
  account and token; S3 keeps everything in the account you already secure.
- **DynamoDB for locking** — deprecated since Terraform 1.11; S3 locks natively.
- **Create the bucket by hand in the console** — then the most important resource in the
  project is the one that is not code.
- **Customer-managed KMS key for encryption** — $1/month; SSE-S3 (AWS-managed) is free
  and enough for this threat model.

## How it works

### The chicken-and-egg problem
The stack creates the bucket its own state should live in, so the state cannot be
there on the first run. The standard solution, used here:
1. First `apply` with **local** state (no `backend` block).
2. Add `backend "s3"` pointing at the new bucket.
3. `terraform init -migrate-state` copies the local state into S3.
4. Delete the local state files; S3 versioning keeps every earlier version.

### State locking
`use_lockfile = true` makes Terraform write `terraform.tfstate.tflock` next to the
state with an S3 **conditional write** ("create only if it does not exist"). A second
run finds the object already there and refuses. The lock is deleted when the run ends.

### Guards
- **`allowed_account_ids`** in the provider: Terraform refuses to touch any other
  account. This laptop's `default` AWS profile is an employer production account; this
  guard is what makes a wrong-profile mistake harmless.
- **`prevent_destroy`** on the bucket: `terraform destroy` fails instead of deleting the
  bucket and every stack's state with it.
- **TLS-only bucket policy**: an explicit `Deny` for any request where
  `aws:SecureTransport` is false. Explicit denies win over any allow, including admin.
- **Public access block + `BucketOwnerEnforced`**: nothing in the bucket can become
  public, and ACLs are switched off (access is IAM and the bucket policy only).

### Budget
AWS Budgets evaluates spend a few times a day and emails when:
- **actual** spend passes 80% of $5, or
- **forecasted** month-end spend passes 100%.

It is detection, not prevention: it cannot stop anything, and it can lag spend by hours.

## Implementation
| File | Contents |
|---|---|
| `versions.tf` | Terraform `>= 1.15.0, < 2.0.0`; AWS provider `~> 6.66`; `backend "s3"` (key `bootstrap/terraform.tfstate`, `use_lockfile`) |
| `providers.tf` | region, `allowed_account_ids`, `default_tags` (Project, Stack, ManagedBy, Repo) |
| `variables.tf` | `account_id`, `region`, and the private values `alert_email`, `alert_phone` (`sensitive = true`, validated) |
| `state_bucket.tf` | bucket + versioning, SSE-S3, public access block, ownership controls, lifecycle (noncurrent versions expire after 90 days), TLS-only policy |
| `budget.tf` | $5 monthly cost budget, actual 80% and forecast 100% email alerts |
| `contacts.tf` | alternate contacts BILLING, OPERATIONS, SECURITY |
| `terraform.tfvars.example` | template; the real `terraform.tfvars` is git-ignored (public repo) |
| `.terraform.lock.hcl` | committed; provider checksums for `darwin_arm64`, `linux_amd64`, `linux_arm64` so CI verifies the same binaries |

`.gitignore` now ignores `.terraform/`, state files, `*.tfvars` (except `*.example`) and
plan files.

## Verification
| Check | Result |
|---|---|
| Account guard (negative control) | with `account_id = 111111111111`: `Error: AWS account ID not allowed: 466558795290` before any API change |
| Plan before apply | 11 to add, 0 change, 0 destroy; email and phone not present in the plan output |
| Bucket settings | versioning `Enabled`, `AES256`, public access block all `True` |
| Signed request over HTTPS | allowed |
| **Same signed request over plain HTTP** | `AccessDenied` (TLS-only policy) |
| **Anonymous request from the internet** | `403` |
| Budget | $5 monthly COST; `ACTUAL 80`, `FORECASTED 100` → the Gmail address |
| Alternate contacts | BILLING, OPERATIONS, SECURITY → the Gmail address |
| State migration | `bootstrap/terraform.tfstate` in S3 (10 resource blocks); plan against it: "No changes" |
| **Locking (negative control)** | two concurrent plans: `.tflock` object present during run 1; run 2 failed `Error acquiring the state lock`; lock gone afterwards |
| After upgrading to Terraform 1.16.4 | `AWS_PROFILE=personal terraform plan` works with no exported credentials: "No changes" |

## Gotchas
- **The backend and the provider authenticate separately.** `plan` and `apply` worked
  with an `aws login` session, then `init -migrate-state` failed with
  `No valid credential sources found`. The S3 backend has its own credential code, and
  it learned `aws login` only in **Terraform 1.15.0** (hashicorp/terraform#37976). The
  interim workaround was `eval "$(aws configure export-credentials --profile personal
  --format env)"` (still temporary `ASIA…` credentials, not keys). Fixed for good by
  upgrading and requiring `>= 1.15.0`.
- **A value on a commented line is not a value.** The phone number was typed into the
  template's `# alert_phone = ...` line; Terraform reported `No value for required
  variable`. Check the file, not the editor.
- **`sensitive = true` hides values from output, not from state.** The email and phone
  are in the state file in S3. That is why the bucket is private, encrypted and TLS-only.
- **Forecast alerts need history.** For the account's first weeks AWS has too little
  data to forecast; the actual-spend alert works from day one.
- **Budget emails need no confirmation.** Unlike SNS email subscriptions, Budgets sends
  directly; the first mail arrives with the first alert.
- **`prevent_destroy` is a speed bump, not a lock.** Removing the line and applying lets
  Terraform delete the bucket. It prevents accidents, not intent.
- **The account id is public** (in code and in the bucket name). AWS does not treat
  account ids as secrets; the guard only works if it is in the code.
- **Lifecycle configuration took 56 s** to create. S3 applies it asynchronously; slow is
  normal.

## Further reading
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform 1.15.0 changelog: backend/s3 supports aws login](https://github.com/hashicorp/terraform/releases/tag/v1.15.0)
- [AWS provider: allowed_account_ids](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#allowed_account_ids-1)
- [S3: enforcing encryption in transit with aws:SecureTransport](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [AWS Budgets: managing costs](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [AWS account alternate contacts](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-update-contact-alternate.html)
