# #11: the node's security group. Inbound: only HTTP/HTTPS from anywhere (Traefik).
# No 22 (SSH) and no 6443 (Kubernetes API): admin access goes over Tailscale (#13),
# which needs no inbound rule (it connects out and uses NAT traversal).
resource "aws_security_group" "node" {
  name        = "k3s-gitops-lab-node"
  description = "K3s node: inbound 80/443 only; admin over Tailscale"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "k3s-gitops-lab-node" }
}

# Separate rule resources (not inline blocks): each rule is its own object in state,
# so adding or removing one never rewrites the others.
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.node.id
  description       = "HTTP (redirects to HTTPS, and Lets Encrypt HTTP-01)" # no apostrophe: EC2 rejects it
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Outbound unrestricted: apt, GHCR image pulls, Tailscale, Let's Encrypt, Grafana Cloud.
# A stateful security group lets replies to these connections back in automatically.
# Accepted (trivy): the node must reach apt mirrors, GHCR, Tailscale (DERP/STUN and
# direct UDP to peers), Let's Encrypt and Grafana Cloud, whose addresses change. A port
# allow-list would still need 0.0.0.0/0 as destination, which this check flags anyway.
# trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
