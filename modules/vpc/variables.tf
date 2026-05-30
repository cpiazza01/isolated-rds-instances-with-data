variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 is required to support public subnet CIDR indices starting at 100."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to create subnets in. One private (and, if enabled, one public) subnet is created per AZ."
  type        = list(string)
}

# When true, an internet gateway and one public /24 subnet per AZ are created.
# Required for the bastion host feature. Public subnets use CIDR indices 100+
# (e.g. 10.0.100.0/24, 10.0.101.0/24) to avoid overlapping with the private
# subnets at indices 0, 1, etc.
variable "enable_public_subnets" {
  description = "When true, creates an internet gateway and one public /24 subnet per AZ. Required for the bastion host feature."
  type        = bool
  default     = false
}

variable "region" {
  description = "AWS region used to construct the Secrets Manager VPC endpoint service name."
  type        = string
}
