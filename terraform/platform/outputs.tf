# Read by the instance stack (terraform/instance) through terraform_remote_state.
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "availability_zone" {
  value = var.availability_zone
}

output "region" {
  value = var.region
}
