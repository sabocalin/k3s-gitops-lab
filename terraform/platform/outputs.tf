# Read by the instance stack (terraform/instance) through terraform_remote_state.
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Availability zone => public subnet id."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "region" {
  value = var.region
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}

output "node_instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "tailscale_secret_parameter" {
  description = "Created out of band (aws ssm put-parameter); Terraform never holds its value."
  value       = local.tailscale_secret_parameter
}

output "autostop_role_arn" {
  value = aws_iam_role.autostop.arn
}
