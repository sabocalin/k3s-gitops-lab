# #12: the node's IAM role. Deliberately tiny: read TWO named SSM parameters (the Tailscale
# OAuth client secret, #12; the DuckDNS token, #36) and register with Session Manager for
# break-glass shell access.
#
# The parameters themselves are NOT managed by Terraform: its value would end up in state (a
# refresh reads SecureString values back). Each is created once, out of band, with
# `aws ssm put-parameter` (runbooks in docs/learning/12-node-iam-and-secret.md and
# 36-dynamic-dns.md). Terraform only knows their names.

locals {
  tailscale_secret_parameter = "/k3s-gitops-lab/tailscale/oauth-client-secret"
  tailscale_secret_arn       = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.tailscale_secret_parameter}"
  duckdns_token_parameter    = "/k3s-gitops-lab/duckdns/token"
  duckdns_token_arn          = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.duckdns_token_parameter}"
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
  description        = "K3s node: read the Tailscale secret and DuckDNS token parameters; Session Manager"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

data "aws_iam_policy_document" "node" {
  # Exactly these parameters, by full name. SecureStrings with the AWS-managed aws/ssm key:
  # its key policy already lets account principals decrypt through SSM, so no kms:Decrypt
  # grant here.
  statement {
    sid       = "ReadTailscaleSecret"
    actions   = ["ssm:GetParameter"]
    resources = [local.tailscale_secret_arn]
  }

  # #36: the dynamic DNS updater (ansible/roles/ddns) runs at every boot with this token.
  statement {
    sid       = "ReadDuckdnsToken"
    actions   = ["ssm:GetParameter"]
    resources = [local.duckdns_token_arn]
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
