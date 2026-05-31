# Pins the minimum Terraform CLI version and declares every provider this
# module needs. Keeping these explicit prevents accidental upgrades from
# quietly changing behaviour during a CI run.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Primary cloud provider — used for VPC, RDS, Lambda, IAM, and SGs.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }

    # Used by the seeder module to zip the Lambda deployment package on-the-fly
    # after the build step installs Python dependencies into lambda/package/.
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }

    # Used by modules/seeder for the build_package and invoke_seeder resources.
    # null_resource is preferred over terraform_data for local-exec provisioners
    # due to a schema availability issue with terraform.io/builtin/terraform in
    # some Terragrunt environments.
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }

    # Used by modules/client_vpn to generate a CA, server cert, and client cert
    # when create_certificates = true. Private keys are stored in Terraform state.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}
