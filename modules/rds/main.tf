locals {
  # The DB port is engine-specific and is used both in the security group
  # ingress rule and surfaced via the outputs so callers don't need to hard-code
  # port numbers in their connection strings.
  port = var.db_engine == "postgres" ? 5432 : 3306

  # AWS requires a parameter group family string that matches the engine's
  # major version. We derive it from the version string so callers don't have
  # to supply it separately:
  #   postgres 16.3  → "postgres16"
  #   mysql    8.0.35 → "mysql8.0"
  pg_family = var.db_engine == "postgres" ? (
    "postgres${split(".", var.db_engine_version)[0]}"
    ) : (
    "mysql${join(".", slice(split(".", var.db_engine_version), 0, 2))}"
  )
}

# Controls which traffic can reach the RDS instance. Ingress is locked down
# to the specific security group(s) passed in (the seeder Lambda's SG) rather
# than a CIDR range. This means only ENIs with that SG attached — i.e. the
# Lambda function — can open a connection to the database port. Nothing else
# inside the VPC can reach RDS unless its SG is added to allowed_security_group_ids.
resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  vpc_id      = var.vpc_id
  description = "RDS — ingress from allowed SGs (seeder Lambda, bastion) and CIDRs (peered VPCs)"

  # Ingress from specific security groups (seeder Lambda, bastion). SG-based
  # rules are preferred over CIDR rules for resources inside the same VPC
  # because they stay correct even if subnet CIDRs change.
  ingress {
    from_port       = local.port
    to_port         = local.port
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
    description     = "DB port from allowed SGs"
  }

  # Ingress from CIDR blocks — used for peered VPCs (e.g. Databricks) where
  # the source resources live in a different VPC and have no SG in this account.
  # The dynamic block is omitted entirely when allowed_cidr_blocks is empty.
  dynamic "ingress" {
    for_each = length(var.allowed_cidr_blocks) > 0 ? [1] : []
    content {
      from_port   = local.port
      to_port     = local.port
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidr_blocks
      description = "DB port from peered VPC CIDR(s)"
    }
  }

  # RDS needs outbound access to reach AWS service endpoints for things like
  # enhanced monitoring and automatic minor version upgrades.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }

  # create_before_destroy prevents a brief window where the RDS instance has
  # no security group attached during a SG replacement (e.g. if the ingress
  # rule changes and AWS forces a new SG to be created).
  lifecycle { create_before_destroy = true }
}

# An RDS subnet group tells AWS which subnets the DB instance (and its
# standby replica, if multi-AZ is ever enabled) may be placed in. The group
# must span at least two AZs even for single-AZ deployments — this is an AWS
# requirement, not a module choice.
resource "aws_db_subnet_group" "main" {
  name_prefix = "${var.name_prefix}-"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${var.name_prefix}-subnet-group" }
}

# A parameter group is a named collection of engine configuration settings
# (analogous to postgresql.conf or my.cnf). We create a dedicated one rather
# than using the AWS default so that future tuning changes can be applied
# through Terraform without touching a shared, account-wide default group.
# The `family` must match the engine version — this is why it is derived from
# the version string in locals above.
resource "aws_db_parameter_group" "main" {
  name_prefix = "${var.name_prefix}-"
  family      = local.pg_family

  tags = { Name = "${var.name_prefix}-pg" }

  # create_before_destroy avoids downtime when the parameter group needs to
  # be replaced (e.g. after an engine version upgrade changes the family).
  lifecycle { create_before_destroy = true }
}

# The RDS instance itself. Key decisions:
#
#   publicly_accessible = false  — no public IP is assigned; the instance is
#     only reachable via its private DNS name from within the VPC.
#
#   storage_encrypted = true  — encrypts data at rest using the AWS-managed
#     KMS key for RDS. Required for most compliance frameworks and has no
#     measurable performance impact on gp3 storage.
#
#   storage_type = "gp3"  — the latest general-purpose SSD tier; cheaper than
#     gp2 at most sizes and provides a guaranteed 3,000 IOPS baseline.
#
#   multi_az = false  — keeps costs low for dev/test. Flip to true for any
#     environment where you care about availability during an AZ outage.
#
#   deletion_protection = false  — allows `terraform destroy` to succeed
#     without an extra manual step. Set to true in production.
resource "aws_db_instance" "main" {
  identifier_prefix = "${var.name_prefix}-"

  engine         = var.db_engine == "postgres" ? "postgres" : "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username

  # RDS generates a strong random password and stores it in AWS Secrets Manager
  # automatically. Terraform never sees or stores the password, so it cannot
  # appear in the state file. The secret ARN is exposed via an output so the
  # seeder Lambda can retrieve the password at runtime.
  manage_master_user_password = true

  allocated_storage = var.db_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  publicly_accessible = false
  multi_az            = false
  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  tags = { Name = "${var.name_prefix}-rds" }
}
