output "db_instance_id" {
  description = "RDS instance identifier. Use with AWS CLI commands targeting this specific instance."
  value       = aws_db_instance.main.id
}

output "db_endpoint" {
  description = "RDS connection endpoint in host:port format. Only reachable from within the VPC."
  value       = aws_db_instance.main.endpoint
}

output "db_host" {
  description = "RDS hostname without port. Use when the DB client takes host and port as separate arguments."
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "Port the RDS instance listens on (5432 for PostgreSQL, 3306 for MySQL)."
  value       = aws_db_instance.main.port
}

output "rds_security_group_id" {
  description = "ID of the RDS security group. Reference this in other SG ingress rules to allow access to the DB port."
  value       = aws_security_group.rds.id
}

# The ARN of the Secrets Manager secret that holds the master user password.
# Pass this to the seeder Lambda so it can call GetSecretValue at runtime.
# The secret itself (and therefore the password) is managed entirely by RDS
# and never surfaces in Terraform state.
output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password. Retrieve with: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = try(aws_db_instance.main.master_user_secret[0].secret_arn, null)
}
