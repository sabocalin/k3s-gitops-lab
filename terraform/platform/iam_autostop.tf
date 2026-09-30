# #62: role for the nightly auto-stop schedule (EventBridge Scheduler, in the instance
# stack). It may stop project-tagged instances in this account and region, nothing else.
# Scoped by tag, not instance id, so it survives instance rebuilds (new id each time).
data "aws_iam_policy_document" "autostop_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    # Confused-deputy guard: only schedules in this account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "autostop" {
  name               = "k3s-gitops-lab-autostop"
  description        = "EventBridge Scheduler: stop project-tagged instances"
  assume_role_policy = data.aws_iam_policy_document.autostop_assume.json
}

data "aws_iam_policy_document" "autostop" {
  statement {
    sid       = "StopProjectInstances"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["k3s-gitops-lab"]
    }
  }
}

resource "aws_iam_role_policy" "autostop" {
  name   = "stop-project-instances"
  role   = aws_iam_role.autostop.id
  policy = data.aws_iam_policy_document.autostop.json
}
