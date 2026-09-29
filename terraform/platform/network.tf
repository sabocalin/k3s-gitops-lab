# Everything in this file is free: VPC, subnet, internet gateway, route table and
# security groups have no hourly charge. The only network cost is the instance's public
# IPv4 address, which exists only while the instance runs (instance stack).

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # instances get resolvable DNS names; needed by some AWS services

  tags = { Name = "k3s-gitops-lab" }
}

# Public subnet: anything launched here gets a public IPv4 address automatically. That
# address is released when the instance stops, so it costs nothing while idle (an
# Elastic IP would bill even while stopped; README "Never create").
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "k3s-gitops-lab-public-${var.availability_zone}" }
}

# Route to the internet through the internet gateway. No NAT Gateway (~$33/month): the
# instance talks to the internet directly with its own public address.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "k3s-gitops-lab" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "k3s-gitops-lab-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Every VPC comes with a "default" security group that allows all traffic between its
# members. Anything launched without an explicit group lands in it. Taking it under
# Terraform with no rules strips it (CIS AWS Foundations benchmark). The instance gets
# its own, explicit security group in #11.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "k3s-gitops-lab-default-deny-all" }
}
