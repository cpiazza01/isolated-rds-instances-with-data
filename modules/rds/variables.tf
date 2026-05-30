variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC in which the RDS instance and its security group are created."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the RDS subnet group. Must span at least two AZs."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the RDS port (seeder Lambda, bastion, Client VPN, etc.)."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the RDS port. Used for peered VPCs such as Databricks."
  type        = list(string)
  default     = []
}

variable "db_engine" {
  description = "RDS engine: 'postgres' or 'mysql'. Determines the port, parameter group family, and Python driver."
  type        = string
}

variable "db_engine_version" {
  description = "Engine version string (e.g. '16.3' for PostgreSQL, '8.0.35' for MySQL)."
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class (e.g. 'db.t3.micro'). Controls CPU and memory."
  type        = string
}

variable "db_name" {
  description = "Name of the initial database created on the instance."
  type        = string
}

variable "db_username" {
  description = "Master username for the RDS instance."
  type        = string
}

variable "db_storage_gb" {
  description = "Allocated storage in GiB (gp3). Can be expanded after creation but not shrunk."
  type        = number
}

variable "snapshot_identifier" {
  description = "ARN or identifier of an RDS snapshot to restore from. When set, the instance is created from the snapshot instead of fresh. db_name and db_username are inherited from the snapshot."
  type        = string
  default     = null
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Set false for anything resembling production."
  type        = bool
}

variable "deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance. Defaults to false for dev/test; set true for staging or production."
  type        = bool
  default     = false
}
