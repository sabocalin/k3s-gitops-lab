# #16: GitHub Actions authenticates to AWS with OIDC: short-lived credentials, no access
# keys anywhere. Three roles:
#
#   plan   pull requests      read-only (+ the Terraform lock file), never the secret
#   apply  main, environment  the node only: EC2 instance and disk, its schedules
#          "production"
#   lab    main, environment  start, stop and lease the existing node (#63)
#          "lab"
#
# These live in the bootstrap stack on purpose: it is applied only from the laptop (admin
# + MFA). A CI role that could change IAM could grant itself more; neither role can touch
# IAM, the VPC or the budget, so network and IAM changes stay a laptop apply.

locals {
  # GitHub's immutable subject format (this repo's OIDC setting, use_immutable_subject):
  # repo:<owner>@<owner id>/<repo>@<repo id>:<context>. The ids never change, so a renamed
  # or re-created repo with the same name cannot inherit these roles.
  # Ids: gh api repos/sabocalin/k3s-gitops-lab --jq '.owner.id, .id'
  github_sub      = "repo:sabocalin@238511101/k3s-gitops-lab@1385841640"
  oidc_host       = "token.actions.githubusercontent.com"
  state_bucket    = aws_s3_bucket.state.arn
  secrets_path    = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/k3s-gitops-lab/*"
  project_tag     = "k3s-gitops-lab"
  allowed_types   = ["t4g.small", "t4g.medium"] # cost guard: CI cannot launch anything bigger
  canonical_owner = "099720109477"              # Ubuntu images only
}

# The identity provider: AWS trusts tokens signed by GitHub's OIDC issuer. No thumbprint:
# AWS validates GitHub's certificate chain itself.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# --- trust policies -------------------------------------------------------------------
# `aud` must be sts.amazonaws.com (what configure-aws-credentials requests), and `sub`
# names exactly where the workflow runs. StringEquals, not StringLike: no wildcards.

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Any pull_request run of this repo. Pull requests from forks get no OIDC token.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["${local.github_sub}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs that run in the "production" environment. GitHub allows that environment
    # on `main` only (deployment branch policy), so a feature branch cannot get here.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["${local.github_sub}:environment:production"]
    }
  }
}

# --- shared: reading is fine, the secret is not ------------------------------------------
# ReadOnlyAccess includes ssm:GetParameter* on every parameter. These denies keep the
# Tailscale secret out of CI. An explicit Deny beats any Allow, and denying decryption
# through SSM also covers GetParametersByPath on a parent path.
data "aws_iam_policy_document" "deny_secrets" {
  statement {
    sid    = "DenyProjectParameters"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
      "ssm:GetParametersByPath",
    ]
    resources = [local.secrets_path]
  }
  statement {
    sid       = "DenyDecryptViaSSM"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

# --- plan role ------------------------------------------------------------------------

resource "aws_iam_role" "github_plan" {
  name                 = "k3s-gitops-lab-github-plan"
  description          = "GitHub Actions on pull requests: terraform plan (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan" {
  source_policy_documents = [data.aws_iam_policy_document.deny_secrets.json]

  # S3-native state locking (use_lockfile) writes <key>.tflock during a plan. Only the
  # lock files: the state itself stays read-only.
  statement {
    sid       = "TerraformLockFiles"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "plan"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan.json
}

# --- apply role -----------------------------------------------------------------------

resource "aws_iam_role" "github_apply" {
  name                 = "k3s-gitops-lab-github-apply"
  description          = "GitHub Actions on main (environment production): the instance stack"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# Reading is needed for refresh and plan; writing is the inline policy below.
resource "aws_iam_role_policy_attachment" "github_apply_readonly" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_apply" {
  source_policy_documents = [data.aws_iam_policy_document.deny_secrets.json]

  # The instance stack's state and lock; the platform state stays read-only.
  statement {
    sid       = "InstanceState"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket}/instance/*"]
  }

  # RunInstances is authorized once per resource it touches. The new instance and disk
  # must carry Project=k3s-gitops-lab (Terraform's default_tags) and be a small type.
  statement {
    sid       = "LaunchProjectInstance"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [local.project_tag]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = local.allowed_types
    }
  }
  statement {
    sid       = "LaunchProjectVolume"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:volume/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [local.project_tag]
    }
  }
  # ...into the project's own subnet and security group...
  statement {
    sid     = "LaunchIntoProjectNetwork"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:${var.region}:${var.account_id}:subnet/*",
      "arn:aws:ec2:${var.region}:${var.account_id}:security-group/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.project_tag]
    }
  }
  # ...from a Canonical (Ubuntu) image, with a fresh network interface. Canonical's
  # images carry the owner ALIAS "amazon", and for an aliased image the ec2:Owner key
  # evaluates to the alias, not the account id: the id alone denied the first CI launch
  # (#64). "amazon" covers AWS-vetted publishers only; the exact image is chosen in code
  # (terraform/instance: owners = Canonical, Ubuntu 24.04 arm64), reviewed like the rest.
  statement {
    sid       = "LaunchFromUbuntuImage"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${var.region}::image/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:Owner"
      values   = [local.canonical_owner, "amazon"]
    }
  }
  statement {
    sid       = "LaunchNetworkInterface"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:network-interface/*"]
  }

  # Tags may be written while launching, or on resources that are already the project's.
  statement {
    sid       = "TagOnLaunch"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }

  # Everything else on the node only: identified by its tag, so it survives rebuilds.
  statement {
    sid = "ManageProjectInstances"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:ModifyInstanceCreditSpecification",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = [
      "arn:aws:ec2:${var.region}:${var.account_id}:instance/*",
      "arn:aws:ec2:${var.region}:${var.account_id}:volume/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.project_tag]
    }
  }

  # Hand the existing roles to the services that use them; never create or change roles.
  statement {
    sid       = "PassNodeRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/k3s-gitops-lab-node"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
  statement {
    sid       = "PassAutostopRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/k3s-gitops-lab-autostop"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }

  # The nightly stop and the session lease (#61, #62).
  statement {
    sid = "ProjectSchedules"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:UpdateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:GetSchedule",
    ]
    resources = ["arn:aws:scheduler:${var.region}:${var.account_id}:schedule/default/k3s-gitops-lab-*"]
  }
}

resource "aws_iam_role_policy" "github_apply" {
  name   = "apply-instance-stack"
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.github_apply.json
}

# --- lab role (#63) ------------------------------------------------------------------
# The "Start lab" button (.github/workflows/lab.yml): start, stop or extend the existing
# node from the GitHub UI or the mobile app. Its own environment ("lab", main only), so
# the button's jobs never see production's secrets, and production's jobs cannot use this
# role. No ReadOnlyAccess: only what scripts/lab.sh start|stop|extend calls.

data "aws_iam_policy_document" "lab_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs in the "lab" environment, which GitHub allows on main only.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["${local.github_sub}:environment:lab"]
    }
  }
}

resource "aws_iam_role" "github_lab" {
  name                 = "k3s-gitops-lab-github-lab"
  description          = "GitHub Actions, environment lab: start, stop and lease the node"
  assume_role_policy   = data.aws_iam_policy_document.lab_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_lab" {
  # Finding the node by tag and waiting for its state. Describe calls have no
  # resource-level permissions: "*" is the only possible resource.
  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  # Start and stop the project's node, nothing else: both tags must match.
  statement {
    sid       = "StartStopProjectNode"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.project_tag]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Stack"
      values   = ["instance"]
    }
  }
  # The session lease (#61): a one-off schedule that stops the node later. Without it, a
  # node started from a phone would run until the nightly stop. This schedule only; the
  # nightly one stays the apply role's.
  statement {
    sid = "SessionLease"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:UpdateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:GetSchedule",
    ]
    resources = ["arn:aws:scheduler:${var.region}:${var.account_id}:schedule/default/k3s-gitops-lab-lease"]
  }
  # The lease runs as the autostop role (#62), which can only stop project instances.
  statement {
    sid       = "PassAutostopRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/k3s-gitops-lab-autostop"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_lab" {
  name   = "start-stop-lease"
  role   = aws_iam_role.github_lab.id
  policy = data.aws_iam_policy_document.github_lab.json
}
