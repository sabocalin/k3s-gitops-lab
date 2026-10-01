# #17: tflint configuration (run by scripts/lint-terraform.sh, locally and in CI).
config {
  # The stacks call no modules; do not try to fetch any.
  call_module_type = "none"
}

# Core Terraform language rules. "all" goes beyond the default "recommended" set:
# typed and documented variables and outputs, naming, standard file layout.
plugin "terraform" {
  enabled = true
  preset  = "all"
}

# Meant for reusable modules (main.tf/variables.tf/outputs.tf). These are root stacks,
# split by concern (network.tf, iam_node.tf, autostop.tf, ...).
rule "terraform_standard_module_structure" {
  enabled = false
}

# AWS provider rules: invalid instance types, AMI and region values, deprecated
# arguments, and more. The plugin is downloaded by `tflint --init` and its signature is
# verified against the key built into tflint. Exact version; bump by hand.
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
