provider "aws" {
  region = var.aws_region
}

locals {
  db_engine_version = var.db_engine_version != null ? var.db_engine_version : (
    var.db_engine == "postgres" ? "16.3" : "8.0.35"
  )
  db_port = var.db_engine == "postgres" ? 5432 : 3306
}

# ── VPC ───────────────────────────────────────────────────────────────────────

# Provisions a fully private VPC with one private subnet per availability zone.
# When enable_bastion = true, the VPC module also creates an internet gateway
# and one public subnet per AZ to host the bastion EC2 instance.
module "vpc" {
  source = "./modules/vpc"

  name_prefix           = var.name_prefix
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  enable_public_subnets = var.enable_bastion
  region                = var.aws_region
}

# ── Seeder Lambda security group ──────────────────────────────────────────────
# Created at the root level to break the circular dependency between modules/rds
# (which needs this SG ID for its ingress rule) and modules/seeder (which needs
# the RDS hostname that only exists after RDS is created). See CLAUDE.md.

resource "aws_security_group" "seeder_lambda" {
  count       = var.enable_seeder ? 1 : 0
  name_prefix = "${var.name_prefix}-seeder-"
  vpc_id      = module.vpc.vpc_id
  description = "Seeder Lambda - restricted egress to RDS port and Secrets Manager endpoint"

  # The Lambda only ever needs two outbound paths:
  # 1. The DB port to reach the RDS instance.
  # 2. HTTPS (443) to reach the Secrets Manager VPC endpoint for the password.
  # Both are scoped to the VPC CIDR rather than 0.0.0.0/0. The SG is created
  # before module.rds (to break the circular dependency), so an SG-reference
  # egress rule to the RDS SG is not possible here — CIDR is the next-best option.
  egress {
    from_port   = local.db_port
    to_port     = local.db_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "DB port to RDS within VPC"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS to Secrets Manager VPC endpoint"
  }

  tags = { Name = "${var.name_prefix}-seeder-sg" }

  lifecycle { create_before_destroy = true }
}

# ── Bastion host (optional) ───────────────────────────────────────────────────

# A small EC2 instance in a public subnet that acts as an SSH jump host.
# Connect via: ssh -N -L <local_port>:<rds_host>:<rds_port> ec2-user@<bastion_ip>
# Then point your DB client at localhost:<local_port>.
#
# Stop the instance when not in use to minimise cost:
#   aws ec2 stop-instances --instance-ids $(terraform output -raw bastion_instance_id)
# Guard: bastion_allowed_cidrs must be non-empty when the bastion is enabled.
# Cross-variable references are not allowed in variable validation blocks, so
# this precondition lives here instead.
resource "null_resource" "bastion_cidr_check" {
  count = var.enable_bastion ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(var.bastion_allowed_cidrs) > 0
      error_message = "bastion_allowed_cidrs must contain at least one CIDR when enable_bastion = true. Check your public IP with: curl -s https://checkip.amazonaws.com"
    }
  }
}

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "./modules/bastion"

  name_prefix      = var.name_prefix
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = try(module.vpc.public_subnet_ids[0], "")
  allowed_cidrs    = var.bastion_allowed_cidrs
  ssh_key_name     = var.bastion_ssh_key_name
}

# ── AWS Client VPN (optional) ─────────────────────────────────────────────────

# Deploys an AWS Client VPN endpoint in the private subnets. Users install the
# AWS VPN Client app and load the .ovpn config to connect — once connected they
# reach the RDS instance directly over the private network, no bastion needed.
# Requires pre-existing ACM certificates; see CLAUDE.md for setup instructions.
#
# Cost note: $0.10/hr per subnet association plus $0.05/hr per active connection.
# Two private subnets ≈ $144/month baseline even when idle — destroy the endpoint
# when not in use.
module "client_vpn" {
  count  = var.enable_client_vpn ? 1 : 0
  source = "./modules/client_vpn"

  name_prefix               = var.name_prefix
  vpc_id                    = module.vpc.vpc_id
  vpc_cidr                  = var.vpc_cidr
  subnet_ids                = module.vpc.private_subnet_ids
  client_cidr_block         = var.client_vpn_cidr
  create_certificates       = var.client_vpn_create_certificates
  client_names              = var.client_vpn_client_names
  server_certificate_arn    = var.client_vpn_server_cert_arn
  root_certificate_arn      = var.client_vpn_root_cert_arn
  split_tunnel              = var.client_vpn_split_tunnel
  enable_connection_logging = var.client_vpn_enable_connection_logging
}

# ── RDS ───────────────────────────────────────────────────────────────────────

# The bastion and Client VPN SGs are added to allowed_security_group_ids when
# they exist, using for expressions over module.bastion / module.client_vpn
# (each a list of 0 or 1 instances) rather than index lookups — safe when
# count = 0.
#
# allowed_cidr_blocks receives the Databricks VPC CIDR when peering is enabled,
# opening the RDS port to traffic arriving from the peered VPC.
module "rds" {
  source = "./modules/rds"

  name_prefix = var.name_prefix
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnet_ids

  allowed_security_group_ids = concat(
    [for s in aws_security_group.seeder_lambda : s.id],
    [for b in module.bastion : b.security_group_id],
    [for v in module.client_vpn : v.security_group_id],
  )
  allowed_cidr_blocks = var.enable_databricks_peering ? [var.databricks_vpc_cidr] : []

  db_engine           = var.db_engine
  db_engine_version   = local.db_engine_version
  db_instance_class   = var.db_instance_class
  db_name             = var.db_name
  db_username         = var.db_username
  db_storage_gb       = var.db_storage_gb
  snapshot_identifier = var.snapshot_identifier
  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.db_deletion_protection
}

# ── Seeder ────────────────────────────────────────────────────────────────────

module "seeder" {
  count  = var.enable_seeder ? 1 : 0
  source = "./modules/seeder"

  name_prefix       = var.name_prefix
  subnet_ids        = module.vpc.private_subnet_ids
  security_group_id = aws_security_group.seeder_lambda[0].id
  aws_region        = var.aws_region

  db_engine      = var.db_engine
  db_host        = module.rds.db_host
  db_port        = local.db_port
  db_name        = var.db_name
  db_username    = var.db_username
  db_secret_arn  = module.rds.db_secret_arn
  db_instance_id = module.rds.db_instance_id

  row_count                      = var.row_count
  invoke_on_apply                = var.seed_on_apply && var.snapshot_identifier == null
  lambda_permission_boundary_arn = var.lambda_permission_boundary_arn
}

# ── Databricks VPC peering (optional) ────────────────────────────────────────

# Establishes a private network link between this VPC and the Databricks
# workspace VPC. Once active, Databricks clusters can connect directly to the
# RDS endpoint using its private DNS name — no internet path, no NAT.
#
# This side of the peering:
#   • Creates the peering connection request.
#   • Adds a route in the private route table so traffic destined for the
#     Databricks CIDR is forwarded across the peering link.
#
# The Databricks side must also:
#   • Accept the peering request (automatic if auto_accept = true and same account).
#   • Add a route in the Databricks VPC route table: this VPC's CIDR → peering ID.
#   • Ensure the Databricks cluster's security group allows outbound TCP on the
#     DB port (5432 / 3306).
resource "aws_vpc_peering_connection" "databricks" {
  count = var.enable_databricks_peering ? 1 : 0

  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = var.databricks_vpc_id

  # Set true only when the Databricks VPC is in the same AWS account.
  # For cross-account peering, leave false and accept manually (or via a
  # separate aws_vpc_peering_connection_accepter resource in the other account).
  auto_accept = var.databricks_peering_auto_accept

  tags = { Name = "${var.name_prefix}-databricks-peering" }
}

# Adds a route to the private route table so that packets destined for the
# Databricks VPC CIDR are forwarded across the peering connection. Without
# this route the packets would be dropped even though the peering is accepted.
resource "aws_route" "to_databricks" {
  count = var.enable_databricks_peering ? 1 : 0

  route_table_id            = module.vpc.private_route_table_id
  destination_cidr_block    = var.databricks_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.databricks[0].id
}
