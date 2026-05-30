# tflint configuration — static analysis for Terraform.
# Run locally: tflint --recursive
# The AWS plugin checks for invalid instance types, deprecated resources, etc.
# Update the version pin periodically: https://github.com/terraform-linters/tflint-ruleset-aws/releases

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Enforce that all modules declare their minimum Terraform version.
rule "terraform_required_version" {
  enabled = true
}

# Enforce that all modules declare required provider versions.
rule "terraform_required_providers" {
  enabled = true
}

# Flag variables and outputs that are declared but never referenced.
rule "terraform_unused_declarations" {
  enabled = true
}

# Warn on deprecated interpolation syntax (e.g. "${var.x}" when var.x suffices).
rule "terraform_deprecated_interpolation" {
  enabled = true
}
