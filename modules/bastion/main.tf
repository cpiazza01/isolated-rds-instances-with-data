# Fetches the latest Amazon Linux 2023 AMI for x86_64. Using a data source
# rather than a hard-coded AMI ID keeps the bastion current with the latest
# security patches and works correctly across all AWS regions.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Controls who can SSH into the bastion. Only the CIDRs in var.allowed_cidrs
# reach port 22 — pass your home/office IP(s) as ["x.x.x.x/32"].
# Outbound is unrestricted so the bastion can forward connections to RDS and
# any other private resource inside the VPC.
resource "aws_security_group" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  vpc_id      = var.vpc_id
  description = "Bastion - SSH inbound from allowed CIDRs only"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
    description = "SSH from allowed CIDRs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = { Name = "${var.name_prefix}-bastion-sg" }

  lifecycle {
    create_before_destroy = true

    # Guard against an empty list, which AWS would reject at the API level
    # with a confusing validation error. Fail early at plan time instead.
    precondition {
      condition     = length(var.allowed_cidrs) > 0
      error_message = "bastion_allowed_cidrs must contain at least one CIDR (e.g. [\"1.2.3.4/32\"]). Check your public IP with: curl -s https://checkip.amazonaws.com"
    }
  }
}

# The bastion EC2 instance. Key decisions:
#
#   instance_type = "t3.nano"  — cheapest general-purpose option (~$0.0052/hr,
#     ~$3.80/month). Stop it via the console or CLI when not in use and pay only
#     for EBS storage (~$0.08/month at 8 GiB gp3).
#
#   associate_public_ip_address = true  — AWS assigns a public IP when the
#     instance starts; it changes each time it is stopped and restarted. Check
#     the current IP with `terraform output bastion_public_ip` or
#     `aws ec2 describe-instances --instance-ids <id>`.
#
#   key_name  — the named key pair must already exist in AWS. The private key
#     is never managed by Terraform.
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.nano"
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.ssh_key_name
  associate_public_ip_address = true

  # Set a recognisable hostname so the instance is easy to identify in logs
  # and SSH known_hosts entries.
  user_data = <<-EOT
    #!/bin/bash
    hostnamectl set-hostname ${var.name_prefix}-bastion
  EOT

  tags = { Name = "${var.name_prefix}-bastion" }
}
