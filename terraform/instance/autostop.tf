# #62: nightly auto-stop. A forgotten running instance is the only realistic way this
# project's cost grows. EventBridge Scheduler calls EC2 StopInstances directly (universal
# target, no Lambda). Stopping an already-stopped instance is a harmless no-op.
resource "aws_scheduler_schedule" "nightly_stop" {
  name        = "k3s-gitops-lab-nightly-stop"
  description = "Stop the K3s node every night (cost safety net)"

  schedule_expression          = "cron(0 23 * * ? *)"
  schedule_expression_timezone = "Europe/Bucharest"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = data.terraform_remote_state.platform.outputs.autostop_role_arn
    input    = jsonencode({ InstanceIds = [aws_instance.node.id] })

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
  }
}
