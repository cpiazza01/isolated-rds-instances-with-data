# RDS module unit tests. Each run block uses `module { source = "..." }` to
# target ./modules/rds directly, so all assertions run against that module's
# plan without going through the root module.
#
# Run: terraform test -filter=tests/rds.tftest.hcl

mock_provider "aws" {}

# ── Parameter group family derivation ────────────────────────────────────────
# The family string is derived by splitting the version on ".":
#   postgres 16.3  → "postgres16"
#   postgres 14.10 → "postgres14"
#   mysql    8.0.35 → "mysql8.0"
# This is the most failure-prone logic in the module — guard it closely.

run "postgres_16_parameter_group_family" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "postgres"
    db_engine_version   = "16.3"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = aws_db_parameter_group.main.family == "postgres16"
    error_message = "postgres 16.3 should map to family 'postgres16', got: ${aws_db_parameter_group.main.family}"
  }
}

run "postgres_14_parameter_group_family" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "postgres"
    db_engine_version   = "14.10"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = aws_db_parameter_group.main.family == "postgres14"
    error_message = "postgres 14.10 should map to family 'postgres14', got: ${aws_db_parameter_group.main.family}"
  }
}

run "mysql_8_parameter_group_family" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "mysql"
    db_engine_version   = "8.0.35"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = aws_db_parameter_group.main.family == "mysql8.0"
    error_message = "mysql 8.0.35 should map to family 'mysql8.0', got: ${aws_db_parameter_group.main.family}"
  }
}

# ── Security group port ───────────────────────────────────────────────────────

run "postgres_security_group_uses_port_5432" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "postgres"
    db_engine_version   = "16.3"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = one(aws_security_group.rds.ingress).from_port == 5432
    error_message = "RDS SG ingress from_port should be 5432 for PostgreSQL"
  }

  assert {
    condition     = one(aws_security_group.rds.ingress).to_port == 5432
    error_message = "RDS SG ingress to_port should be 5432 for PostgreSQL"
  }
}

run "mysql_security_group_uses_port_3306" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "mysql"
    db_engine_version   = "8.0.35"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = one(aws_security_group.rds.ingress).from_port == 3306
    error_message = "RDS SG ingress from_port should be 3306 for MySQL"
  }

  assert {
    condition     = one(aws_security_group.rds.ingress).to_port == 3306
    error_message = "RDS SG ingress to_port should be 3306 for MySQL"
  }
}

# ── Dynamic CIDR ingress block ────────────────────────────────────────────────

run "no_cidr_ingress_when_allowed_cidr_blocks_empty" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "postgres"
    db_engine_version   = "16.3"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
  }

  assert {
    condition     = length(aws_security_group.rds.ingress) == 1
    error_message = "Should have exactly one ingress rule (SG-based) when allowed_cidr_blocks is empty"
  }
}

run "cidr_ingress_added_when_cidr_blocks_provided" {
  command = plan

  module {
    source = "./modules/rds"
  }

  variables {
    name_prefix         = "test"
    vpc_id              = "vpc-mock00000000"
    subnet_ids          = ["subnet-mock0001", "subnet-mock0002"]
    db_engine           = "postgres"
    db_engine_version   = "16.3"
    db_instance_class   = "db.t3.micro"
    db_name             = "testdb"
    db_username         = "testadmin"
    db_storage_gb       = 20
    skip_final_snapshot = true
    allowed_cidr_blocks = ["10.1.0.0/16"]
  }

  assert {
    condition     = length(aws_security_group.rds.ingress) == 2
    error_message = "Should have two ingress rules (SG-based + CIDR-based) when allowed_cidr_blocks is non-empty"
  }
}
