variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_id" { type = string }

variable "allowed_cidrs" {
  description = "CIDRs allowed to SSH into the bastion (e.g. [\"1.2.3.4/32\"]). Avoid 0.0.0.0/0."
  type        = list(string)
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair in this region. Create one via the AWS console or `aws ec2 create-key-pair`."
  type        = string
}
