output "instance_id" {
  value = aws_instance.node.id
}

locals {
  # Empty while the instance is stopped: the auto-assigned address is released.
  public_ip = aws_instance.node.public_ip == "" ? null : aws_instance.node.public_ip
}

output "public_ip" {
  description = "Changes on every start (auto-assigned, released when stopped); null while stopped."
  value       = local.public_ip
}

output "sslip_hostname" {
  description = "Wildcard DNS that resolves to the public IP; used for Ingress and TLS (#35). Null while stopped."
  value       = local.public_ip == null ? null : "${replace(local.public_ip, ".", "-")}.sslip.io"
}

output "ami" {
  value = aws_instance.node.ami
}
