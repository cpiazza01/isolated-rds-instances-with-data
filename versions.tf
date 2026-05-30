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

    # terraform_data (built-in since 1.4) replaced null_resource for local-exec
    # provisioners, so the null provider is no longer needed.

    # Used by modules/client_vpn to generate a CA, server cert, and client cert
    # when create_certificates = true. Private keys are stored in Terraform state.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}
