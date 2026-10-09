# Read by the instance stack (terraform/instance) through terraform_remote_state.
output "vpc_id" {
  description = "The project VPC (10.42.0.0/16)."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Availability zone => public subnet id."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "region" {
  description = "Region of every stack."
  value       = var.region
}

output "node_security_group_id" {
  description = "Security group for the node: inbound 80/443 only."
  value       = aws_security_group.node.id
}

output "node_instance_profile_name" {
  description = "Instance profile carrying the node role."
  value       = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  description = "The node role (two SSM parameters, the node identity, the ESO role, Session Manager)."
  value       = aws_iam_role.node.arn
}

output "tailscale_secret_parameter" {
  description = "Created out of band (aws ssm put-parameter); Terraform never holds its value."
  value       = local.tailscale_secret_parameter
}

output "duckdns_token_parameter" {
  description = "Created out of band (aws ssm put-parameter, #36); Terraform never holds its value."
  value       = local.duckdns_token_parameter
}

output "autostop_role_arn" {
  description = "Role EventBridge Scheduler uses to stop the node (nightly stop, lease)."
  value       = aws_iam_role.autostop.arn
}

output "eso_role_arn" {
  description = "Role External Secrets Operator assumes to read /k3s-gitops-lab/grafana-cloud/* (#54)."
  value       = aws_iam_role.eso.arn
}

output "node_identity_prefix" {
  description = "SSM path of the saved node identity a rebuilt node restores at first boot (#64)."
  value       = local.node_identity_prefix
}
