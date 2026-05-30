variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type = list(string)
}

# When true, an internet gateway and one public /24 subnet per AZ are created.
# Required for the bastion host feature. Public subnets use CIDR indices 100+
# (e.g. 10.0.100.0/24, 10.0.101.0/24) to avoid overlapping with the private
# subnets at indices 0, 1, etc.
variable "enable_public_subnets" {
  type    = bool
  default = false
}

variable "region" {
  description = "AWS region used to construct the Secrets Manager VPC endpoint service name."
  type        = string
}
