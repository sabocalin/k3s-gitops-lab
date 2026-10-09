# Outputs of the permanent platform stack (subnet, security group), read from its state.
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "k3s-gitops-lab-tfstate-466558795290"
    key    = "platform/terraform.tfstate"
    region = "eu-central-1"
  }
}

# Canonical publishes the current Ubuntu image id as a public SSM parameter: the
# official "latest 24.04 arm64 on gp3" pointer, no AMI-name or owner filters to get wrong.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.insecure_value
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.platform.outputs.public_subnet_ids[var.availability_zone]
  vpc_security_group_ids = [data.terraform_remote_state.platform.outputs.node_security_group_id]
  iam_instance_profile   = data.terraform_remote_state.platform.outputs.node_instance_profile_name

  # t4g defaults to "unlimited" (this account's default too): sustained CPU above the
  # baseline is billed as surplus credits. "standard" throttles instead of charging.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only (session tokens; blocks SSRF-style credential theft). Hop limit 1: a
  # container one network hop away cannot reach the metadata service. It stays 1: External
  # Secrets runs its controller with hostNetwork instead (#54), so no other pod gets the
  # node role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true # AWS-managed EBS key: free
    delete_on_termination = true
  }

  # No key pair: port 22 is closed anyway; admin access comes over Tailscale (#13).

  # First-boot script: installs Tailscale, joins the tailnet (secret read from SSM at boot,
  # only the parameter name is in here). cloud-init runs user_data once, on first boot, so
  # a change must replace the instance to take effect.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region           = var.region
    secret_parameter = data.terraform_remote_state.platform.outputs.tailscale_secret_parameter
    tag              = "tag:k3s"
    hostname         = "k3s-node"
    # #64: where scripts/save-node-identity.sh saved the node identity, and what to clone.
    identity_prefix = data.terraform_remote_state.platform.outputs.node_identity_prefix
    repo_url        = "https://github.com/sabocalin/k3s-gitops-lab.git"
  })
  user_data_replace_on_change = true

  tags        = { Name = "k3s-gitops-lab-node" }
  volume_tags = { Name = "k3s-gitops-lab-node-root" }

  lifecycle {
    # Canonical publishes new images often; without this every plan would want to
    # replace the instance. The weekly rebuild (#64) picks up the latest image instead.
    ignore_changes = [ami]
  }
}
