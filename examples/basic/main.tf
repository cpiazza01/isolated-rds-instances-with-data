module "isolated_rds" {
  source = "../../"

  name_prefix        = "demo-rds"
  aws_region         = "us-east-1"
  availability_zones = ["us-east-1a", "us-east-1b"]

  db_engine         = "postgres"
  db_engine_version = "16.3"
  db_instance_class = "db.t3.micro"
  db_name           = "appdb"
  db_username       = "dbadmin"

  row_count = 5000
}

output "db_endpoint" {
  value = module.isolated_rds.db_endpoint
}

output "db_secret_arn" {
  description = "Retrieve the password with: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = module.isolated_rds.db_secret_arn
}

output "seeder_lambda" {
  value = module.isolated_rds.seeder_lambda_name
}
