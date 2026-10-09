# #54: the role External Secrets Operator reads SSM parameters with. ESO's controller runs
# with hostNetwork, so it reaches the instance metadata service (IMDS hop limit 1: no other
# pod can) and gets the node role's credentials. It then assumes THIS role
# (ClusterSecretStore spec.provider.aws.role), which can read one path only. The node role
# can also read the Tailscale secret, the DuckDNS token and the node identity; an
# ExternalSecret asking for any of those is denied here, whatever its YAML says.

locals {
  eso_parameter_path = "/k3s-gitops-lab/grafana-cloud/"
}

data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.node.arn]
    }
  }
}

resource "aws_iam_role" "eso" {
  name                 = "k3s-gitops-lab-eso"
  description          = "External Secrets Operator (via the node role): read /k3s-gitops-lab/grafana-cloud/* only"
  assume_role_policy   = data.aws_iam_policy_document.eso_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "eso" {
  # GetParameter(s) under the path; the AWS-managed aws/ssm key's policy already allows
  # decryption through SSM for account principals, so no kms grant.
  statement {
    sid       = "ReadGrafanaCloudParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.eso_parameter_path}*"]
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "read-grafana-cloud-parameters"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}
