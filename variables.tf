# A short string prepended to every resource name and tag, making it easy to
# identify all resources belonging to this stack in the AWS console and to
# run multiple stacks in the same account without name collisions.
variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "isolated-rds"
}

# Determines which AWS region all resources are deployed into. Changing this
# after initial apply will destroy and recreate everything in the new region.
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# RDS requires its subnet group to span at least two availability zones for
# high-availability support, even when multi_az = false. The subnets are also
# used for the seeder Lambda so it can reach the RDS endpoint within the VPC.
variable "availability_zones" {
  description = "At least two AZs — required for the RDS subnet group."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# The IP address range for the VPC. The module carves /24 subnets out of this
# block using cidrsubnet(), one per availability zone. The default /16 gives
# 256 possible /24 subnets — plenty of headroom if more AZs are added later.
variable "vpc_cidr" {
  description = "CIDR block for the private VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# ── Database ──────────────────────────────────────────────────────────────────

# Selects between PostgreSQL and MySQL. The choice affects the engine string
# sent to AWS, the parameter group family, the default port (5432 vs 3306),
# and which Python driver the seeder Lambda imports at runtime.
variable "db_engine" {
  description = "RDS engine: 'postgres' or 'mysql'."
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["postgres", "mysql"], var.db_engine)
    error_message = "db_engine must be 'postgres' or 'mysql'."
  }
}

# Pinning a specific version avoids surprise upgrades when AWS releases a new
# minor version. Leave null to use the module's built-in defaults (postgres 16.3
# or mysql 8.0.35). These defaults will eventually become stale — if apply fails
# with an "invalid engine version" error, pass the current minor version
# explicitly (check with: aws rds describe-db-engine-versions --engine postgres).
variable "db_engine_version" {
  description = "Engine version. Leave null for the module default (postgres 16.3 / mysql 8.0.35). Pin explicitly to avoid breakage when AWS deprecates old minor versions."
  type        = string
  default     = null
}

# Controls the CPU and memory available to the RDS instance. db.t3.micro is
# the smallest (and cheapest) option — sufficient for development and testing.
# Scale up to db.t3.medium or larger for heavier workloads.
variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

# The logical database name created inside the RDS instance. Application
# connection strings should reference this name. Changing it after the
# instance is created does NOT rename the existing database.
variable "db_name" {
  description = "Name of the initial database created on the instance."
  type        = string
  default     = "appdb"
}

# The master (superuser) account for the RDS instance. This user has full
# privileges and is used by the seeder Lambda to create the users table and
# insert rows. For real workloads, create a least-privilege app user instead.
variable "db_username" {
  description = "Master username."
  type        = string
  default     = "dbadmin"
}

# Minimum storage allocated to the RDS instance. gp3 storage can be expanded
# after creation but never shrunk, so start conservatively for dev environments.
variable "db_storage_gb" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

# When true, `terraform destroy` skips creating a final DB snapshot before
# deleting the instance — safe for ephemeral dev/test stacks where you don't
# need a recovery point. Always set to false for production-like environments.
variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Set false for anything resembling production."
  type        = bool
  default     = true
}

# When true, the RDS instance cannot be deleted — `terraform destroy` will fail
# until this is set back to false and re-applied. Defaults to false so dev/test
# stacks can be torn down without extra steps. Set true for staging/production.
variable "db_deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance. Set true for staging or production environments."
  type        = bool
  default     = false
}

# ── Bastion host ─────────────────────────────────────────────────────────────

# When true, an internet gateway, public subnets, and a t3.nano EC2 instance
# are added. Use SSH local-port forwarding to reach RDS from your machine:
#   ssh -N -L 5432:<rds_host>:5432 ec2-user@<bastion_public_ip>
variable "enable_bastion" {
  description = "Deploy a bastion EC2 for SSH-tunnel access to RDS from a local machine."
  type        = bool
  default     = false
}

# The key pair must already exist in AWS for the target region. Create one via:
#   aws ec2 create-key-pair --key-name my-key --query KeyMaterial --output text > my-key.pem
variable "bastion_ssh_key_name" {
  description = "Name of an existing EC2 key pair. Required when enable_bastion = true."
  type        = string
  default     = null
}

# Restrict SSH access to known IPs. Use ["x.x.x.x/32"] for a single address.
# Check your public IP with: curl -s https://checkip.amazonaws.com
variable "bastion_allowed_cidrs" {
  description = "CIDRs permitted to SSH to the bastion (e.g. [\"1.2.3.4/32\"]). Required when enable_bastion = true."
  type        = list(string)
  default     = []
}

# ── AWS Client VPN ────────────────────────────────────────────────────────────

# When true, an AWS Client VPN endpoint is created in the private subnets.
# VPN clients (AWS VPN Client, Tunnelblick, OpenVPN) connect with a certificate
# and can reach the RDS instance over the private network — no bastion needed.
# Requires pre-existing ACM certificates; see CLAUDE.md for setup instructions.
#
# Cost: $0.10/hr per subnet association — with two AZs that is ~$144/month
# even when no clients are connected. Destroy the endpoint when not in use.
variable "enable_client_vpn" {
  description = "Deploy an AWS Client VPN endpoint for private-network access to RDS from a local machine."
  type        = bool
  default     = false
}

# Must not overlap with the VPC CIDR or any other CIDR reachable from the VPC.
# "172.16.0.0/22" is a safe choice when the VPC uses the 10.0.0.0/8 range.
# /22 (~1,000 addresses) is the smallest AWS allows and fits this tool's scale.
variable "client_vpn_cidr" {
  description = "CIDR block for VPN client IPs. Must not overlap with vpc_cidr. Required when enable_client_vpn = true."
  type        = string
  default     = "172.16.0.0/22"
}

# When true, the client_vpn module generates a CA, server cert, and client cert
# using the tls provider and imports them into ACM automatically — no EasyRSA
# or manual ACM setup needed. The trade-off is that private keys are stored in
# Terraform state. Acceptable for dev/test; use false for production-grade PKI.
variable "client_vpn_create_certificates" {
  description = "Auto-generate and import ACM certificates. Private keys will be stored in Terraform state. Defaults to false."
  type        = bool
  default     = false
}

# Only required when client_vpn_create_certificates = false.
# Generate and import this certificate with EasyRSA — see CLAUDE.md.
variable "client_vpn_server_cert_arn" {
  description = "ARN of the ACM certificate for the VPN server. Required when client_vpn_create_certificates = false."
  type        = string
  default     = null
}

# Only required when client_vpn_create_certificates = false.
# The CA certificate used to validate client certificates (mutual TLS). Any
# client presenting a cert signed by this CA is authenticated. Must be
# imported into ACM in the same region as the VPN endpoint.
variable "client_vpn_root_cert_arn" {
  description = "ARN of the ACM CA certificate for client authentication. Required when client_vpn_create_certificates = false."
  type        = string
  default     = null
}

# One certificate/key pair is generated per entry when client_vpn_create_certificates
# = true. Remove a name and re-apply to revoke that user's access without
# affecting other clients. Ignored when client_vpn_create_certificates = false.
variable "client_vpn_client_names" {
  description = "VPN client names. One cert/key pair is generated per entry when client_vpn_create_certificates = true."
  type        = list(string)
  default     = ["client"]

  validation {
    condition     = length(var.client_vpn_client_names) > 0
    error_message = "client_vpn_client_names must contain at least one entry."
  }
}

# When enabled, connection events are written to a CloudWatch log group for
# auditing. Disabled by default for dev/test; recommended for production.
variable "client_vpn_enable_connection_logging" {
  description = "Write VPN connection events to CloudWatch Logs. Recommended for production."
  type        = bool
  default     = false
}

# With split tunnel enabled (default), only traffic destined for the VPC CIDR
# is routed through the VPN. Clients keep their existing internet path for
# everything else, which reduces VPN data-transfer costs and latency.
variable "client_vpn_split_tunnel" {
  description = "Route only VPC traffic through the VPN (true) or all client traffic (false)."
  type        = bool
  default     = true
}

# ── Databricks VPC peering ────────────────────────────────────────────────────

# When true, a VPC peering connection is created between this VPC and the
# Databricks workspace VPC. The Databricks CIDR is added to the RDS security
# group ingress, and a route is added to the private route table.
# The Databricks side must also add a return route — see README.md.
variable "enable_databricks_peering" {
  description = "Create a VPC peering connection to the Databricks workspace VPC."
  type        = bool
  default     = false
}

# Find the VPC ID in the Databricks console under Compute → Clusters → Network.
variable "databricks_vpc_id" {
  description = "VPC ID of the Databricks workspace. Required when enable_databricks_peering = true."
  type        = string
  default     = null
}

# The full CIDR of the Databricks VPC (e.g. "10.1.0.0/16"). Used for the RDS
# security group ingress rule and the peering route.
variable "databricks_vpc_cidr" {
  description = "CIDR of the Databricks VPC. Required when enable_databricks_peering = true."
  type        = string
  default     = null
}

# Set true only when the Databricks VPC is in the same AWS account as this
# module. For cross-account workspaces (the common enterprise case) leave false
# and accept the peering request from the Databricks account.
variable "databricks_peering_auto_accept" {
  description = "Auto-accept the peering request. Only valid when the Databricks VPC is in the same AWS account."
  type        = bool
  default     = false
}

# ── Seeding ───────────────────────────────────────────────────────────────────

# How many rows to insert into the `users` table. The seeder batches inserts
# in groups of 500 to avoid transaction timeouts. Lambda has a hard 15-minute
# execution limit; in practice ~500 k rows is safe, with ~1 M rows being the
# theoretical upper bound before the timeout is likely to be hit.
variable "row_count" {
  description = "Number of rows to seed into the users table. Max ~500 k before Lambda 15-min timeout."
  type        = number
  default     = 1000

  validation {
    condition     = var.row_count >= 1 && var.row_count <= 1000000
    error_message = "row_count must be between 1 and 1,000,000."
  }
}
