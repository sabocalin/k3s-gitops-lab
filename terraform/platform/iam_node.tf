# #12: the node's IAM role. Deliberately tiny: read ONE SSM parameter (the Tailscale
# OAuth client secret) and register with Session Manager for break-glass shell access.
#
# The parameter itself is NOT managed by Terraform: its value would end up in state (a
# refresh reads SecureString values back). It is created once, out of band, with
# `aws ssm put-parameter` (runbook in docs/learning/12-node-iam-and-secret.md). Terraform
# only knows its name.

locals {
  tailscale_secret_parameter = "/k3s-gitops-lab/tailscale/oauth-client-secret"
  tailscale_secret_arn       = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.tailscale_secret_parameter}"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "k3s-gitops-lab-node"
  description        = "K3s node: read the Tailscale secret parameter; Session Manager"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

data "aws_iam_policy_document" "node" {
  # Exactly one parameter. SecureString with the AWS-managed aws/ssm key: its key policy
  # already lets account principals decrypt through SSM, so no kms:Decrypt grant here.
  statement {
    sid       = "ReadTailscaleSecret"
    actions   = ["ssm:GetParameter"]
    resources = [local.tailscale_secret_arn]
  }

  # Minimal Session Manager (no port 22, no key pair). NOT AmazonSSMManagedInstanceCore:
  # that managed policy also allows ssm:GetParameter(s) on every parameter.
  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # these actions do not support resource-level restrictions
  }
}

resource "aws_iam_role_policy" "node" {
  name   = "node"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "k3s-gitops-lab-node"
  role = aws_iam_role.node.name
}
