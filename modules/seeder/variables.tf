variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the Lambda VPC config. The function places an ENI in each subnet."
  type        = list(string)
}

variable "security_group_id" {
  description = "Pre-created SG for the Lambda (created in root to break the circular dependency with RDS)."
  type        = string
}

variable "aws_region" {
  description = "AWS region used in the Lambda invoke command during local-exec."
  type        = string
}

variable "db_engine" {
  description = "RDS engine: 'postgres' or 'mysql'. Determines which Python driver seed.py imports."
  type        = string
}

variable "db_host" {
  description = "Hostname of the RDS instance. Injected as an environment variable into the Lambda."
  type        = string
}

variable "db_port" {
  description = "Port the RDS instance listens on (5432 for PostgreSQL, 3306 for MySQL)."
  type        = number
}

variable "db_name" {
  description = "Name of the database to seed."
  type        = string
}

variable "db_username" {
  description = "Master username used by the seeder to connect to RDS."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password."
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance ID — used as a trigger so the invoke re-runs when the instance is replaced."
  type        = string
}

variable "row_count" {
  description = "Number of rows to insert into the users table."
  type        = number
}

variable "invoke_on_apply" {
  description = "When false, the Lambda is deployed but not automatically invoked during apply. Set false when restoring from a snapshot to preserve the restored data."
  type        = bool
  default     = true
}

variable "lambda_permission_boundary_arn" {
  description = "ARN of an IAM permissions boundary to attach to the seeder Lambda execution role. Required in accounts where IAM role creation is restricted to roles with a specific boundary."
  type        = string
  default     = null
}
