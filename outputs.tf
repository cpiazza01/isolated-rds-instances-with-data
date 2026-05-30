# The VPC ID is useful when callers want to peer this VPC with another, attach
# a VPN, or reference it in additional security group rules outside this module.
output "vpc_id" {
  description = "ID of the private VPC."
  value       = module.vpc.vpc_id
}

# Expose the VPC CIDR so Databricks admins can configure the return route on
# their side when enable_databricks_peering = true. They need to add a route
# in the Databricks VPC route table pointing this CIDR at the peering connection.
output "vpc_cidr" {
  description = "CIDR block of the VPC. Needed as the return-route destination when setting up Databricks VPC peering."
  value       = var.vpc_cidr
}

# Subnet IDs are exposed so callers can deploy additional workloads (e.g.
# application servers, extra Lambda functions) into the same private network
# alongside the RDS instance.
output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = module.vpc.private_subnet_ids
}

# The RDS instance identifier is handy for CLI commands such as
# `aws rds describe-db-instances --db-instance-identifier <id>` and for
# constructing IAM policies that target this specific instance.
output "db_instance_id" {
  description = "RDS instance identifier."
  value       = module.rds.db_instance_id
}

# The full endpoint string in host:port format — ready to paste directly into
# a connection string. Because the instance is not publicly accessible, this
# endpoint is only reachable from within the VPC.
output "db_endpoint" {
  description = "RDS connection endpoint (host:port)."
  value       = module.rds.db_endpoint
}

# The bare hostname, separated from the port, for tools that take host and
# port as distinct arguments (e.g. psql -h <host> -p <port>).
output "db_host" {
  description = "RDS hostname."
  value       = module.rds.db_host
}

# The port the RDS instance listens on (5432 for PostgreSQL, 3306 for MySQL).
output "db_port" {
  description = "RDS port."
  value       = module.rds.db_port
}

# The seeder Lambda name is useful for re-running the seed step manually
# without re-applying the whole stack:
#   aws lambda invoke --function-name <name> response.json
output "seeder_lambda_name" {
  description = "Name of the seeder Lambda function. null when enable_seeder = false."
  value       = var.enable_seeder ? module.seeder[0].lambda_function_name : null
}

# ── Bastion ───────────────────────────────────────────────────────────────────

# The public IP changes each time the bastion is stopped and restarted.
# SSH tunnel example (PostgreSQL):
#   ssh -N -L 5432:<db_host>:5432 ec2-user@<bastion_public_ip>
# Then connect locally: psql -h localhost -p 5432 -U dbadmin -d appdb
output "bastion_public_ip" {
  description = "Public IP of the bastion host (null when enable_bastion = false)."
  value       = one([for b in module.bastion : b.public_ip])
}

# Start/stop the bastion to control costs:
#   aws ec2 stop-instances  --instance-ids $(terraform output -raw bastion_instance_id)
#   aws ec2 start-instances --instance-ids $(terraform output -raw bastion_instance_id)
output "bastion_instance_id" {
  description = "EC2 instance ID of the bastion host (null when enable_bastion = false)."
  value       = one([for b in module.bastion : b.instance_id])
}

# Assembles the full SSH tunnel command so there is nothing to look up or
# type manually after apply. The public IP changes on each start, so re-run
# `terraform output bastion_ssh_tunnel_command` after restarting the instance.
output "bastion_ssh_tunnel_command" {
  description = "Ready-to-use SSH tunnel command (null when enable_bastion = false). Run this, then connect your DB client to localhost:<db_port>."
  value = one([
    for b in module.bastion :
    "ssh -N -L ${module.rds.db_port}:${module.rds.db_host}:${module.rds.db_port} ec2-user@${b.public_ip}"
  ])
}

# ── AWS Client VPN ────────────────────────────────────────────────────────────

# Use this ID to export the client configuration file (.ovpn) that users import
# into the AWS VPN Client app:
#   aws ec2 export-client-vpn-client-configuration \
#     --client-vpn-endpoint-id <id> --output text > client-config.ovpn
# Then append the client certificate and private key to client-config.ovpn.
output "client_vpn_endpoint_id" {
  description = "ID of the Client VPN endpoint (null when enable_client_vpn = false)."
  value       = one([for v in module.client_vpn : v.endpoint_id])
}

output "client_vpn_dns_name" {
  description = "DNS name of the Client VPN endpoint (null when enable_client_vpn = false)."
  value       = one([for v in module.client_vpn : v.dns_name])
}

# Assembles the full export command so there is nothing to look up after apply.
# After running it, edit client-config.ovpn to embed the client cert and key:
#   echo "<cert>" >> client-config.ovpn && cat client.crt >> client-config.ovpn && echo "</cert>" >> client-config.ovpn
#   echo "<key>"  >> client-config.ovpn && cat client.key  >> client-config.ovpn && echo "</key>"  >> client-config.ovpn
output "client_vpn_config_cmd" {
  description = "Ready-to-run command to download the VPN client configuration file (null when enable_client_vpn = false)."
  value = one([
    for v in module.client_vpn :
    "aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id ${v.endpoint_id} --region ${var.aws_region} --output text > client-config.ovpn"
  ])
}

# Maps of client name → PEM, one entry per name in client_vpn_client_names.
# Both are null when enable_client_vpn = false, and empty maps when
# client_vpn_create_certificates = false. See CLAUDE.md for embedding steps.
#
# Retrieve a specific user's cert/key:
#   terraform output -json client_vpn_client_cert_pem | jq -r '.alice'
#   terraform output -json client_vpn_client_key_pem  | jq -r '.alice'
output "client_vpn_client_cert_pem" {
  description = "Map of client name to certificate PEM (null when enable_client_vpn = false; empty when client_vpn_create_certificates = false)."
  sensitive   = true
  value       = one([for v in module.client_vpn : v.client_certificate_pem])
}

output "client_vpn_client_key_pem" {
  description = "Map of client name to private key PEM (null when enable_client_vpn = false; empty when client_vpn_create_certificates = false). Keep secret."
  sensitive   = true
  value       = one([for v in module.client_vpn : v.client_private_key_pem])
}

# ── Databricks peering ────────────────────────────────────────────────────────

# Share this ID with the Databricks account owner so they can add the return
# route in their VPC route table and (for cross-account) accept the request.
output "databricks_peering_id" {
  description = "VPC peering connection ID (null when enable_databricks_peering = false)."
  value       = one([for p in aws_vpc_peering_connection.databricks : p.id])
}

# The ARN of the Secrets Manager secret holding the RDS master password.
# Useful for granting other applications read access to the same credential,
# or for inspecting the password manually:
#   aws secretsmanager get-secret-value --secret-id <arn> --query SecretString
output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password."
  value       = module.rds.db_secret_arn
}
