# Everything in this file is free: VPC, subnet, internet gateway, route table and
# security groups have no hourly charge. The only network cost is the instance's public
# IPv4 address, which exists only while the instance runs (instance stack).

# Accepted (trivy): flow logs bill per GB ingested; enable them temporarily when debugging.
# trivy:ignore:AWS-0178
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # instances get resolvable DNS names; needed by some AWS services

  tags = { Name = "k3s-gitops-lab" }
}

# Public subnets, one per availability zone: anything launched here gets a public IPv4
# address automatically. That address is released when the instance stops, so it costs
# nothing while idle (an Elastic IP would bill even while stopped; README "Never create").
# Several zones because a single zone can run out of capacity for an instance type (it
# happened to t4g.small in eu-central-1a); subnets are free.
# Accepted (trivy): public IPs are the design: no NAT gateway (~$33/month); inbound is
# limited by the node's security group to 80/443.
# trivy:ignore:AWS-0164
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = { Name = "k3s-gitops-lab-public-${each.key}" }
}

# The single subnet became one entry of the for_each: same object, new address. Without
# this, Terraform would plan destroy + create, and a subnet in use cannot be destroyed.
moved {
  from = aws_subnet.public
  to   = aws_subnet.public["eu-central-1a"]
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
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

moved {
  from = aws_route_table_association.public
  to   = aws_route_table_association.public["eu-central-1a"]
}

# Every VPC comes with a "default" security group that allows all traffic between its
# members. Anything launched without an explicit group lands in it. Taking it under
# Terraform with no rules strips it (CIS AWS Foundations benchmark). The instance gets
# its own, explicit security group in #11.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "k3s-gitops-lab-default-deny-all" }
}
