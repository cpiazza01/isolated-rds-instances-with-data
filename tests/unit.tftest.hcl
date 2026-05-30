# Root-module unit tests. All providers are mocked — no AWS credentials needed
# and no real infrastructure is created.
#
# Run all tests:   terraform test
# Run this file:   terraform test -filter=tests/unit.tftest.hcl
# Verbose output:  terraform test -verbose

mock_provider "aws" {}
mock_provider "null" {}
mock_provider "archive" {}
mock_provider "random" {}
mock_provider "tls" {}

# ── Variable validation ───────────────────────────────────────────────────────

run "invalid_engine_is_rejected" {
  command = plan

  variables {
    db_engine = "oracle"
  }

  # The validation block on var.db_engine should cause this plan to fail.
  expect_failures = [var.db_engine]
}

run "row_count_zero_is_rejected" {
  command = plan

  variables {
    row_count = 0
  }

  expect_failures = [var.row_count]
}

run "row_count_above_maximum_is_rejected" {
  command = plan

  variables {
    row_count = 1000001
  }

  expect_failures = [var.row_count]
}

# ── Default configuration ─────────────────────────────────────────────────────

run "defaults_create_no_optional_resources" {
  command = plan
  # No variables needed — all have safe defaults.

  assert {
    condition     = length(module.bastion) == 0
    error_message = "Bastion module should not be instantiated when enable_bastion = false (the default)"
  }

  assert {
    condition     = length(module.client_vpn) == 0
    error_message = "Client VPN module should not be instantiated when enable_client_vpn = false (the default)"
  }

  assert {
    condition     = length(aws_vpc_peering_connection.databricks) == 0
    error_message = "Peering connection should not be created when enable_databricks_peering = false (the default)"
  }

  assert {
    condition     = length(aws_route.to_databricks) == 0
    error_message = "Peering route should not be created when enable_databricks_peering = false (the default)"
  }
}

# ── Bastion host ──────────────────────────────────────────────────────────────

run "bastion_creates_one_module_instance" {
  command = plan

  variables {
    enable_bastion        = true
    bastion_ssh_key_name  = "my-test-key"
    bastion_allowed_cidrs = ["10.0.0.0/8"]
  }

  assert {
    condition     = length(module.bastion) == 1
    error_message = "Exactly one bastion module instance should be created when enable_bastion = true"
  }
}

run "bastion_disabled_creates_no_instance" {
  command = plan

  variables {
    enable_bastion = false
  }

  assert {
    condition     = length(module.bastion) == 0
    error_message = "No bastion module instance should exist when enable_bastion = false"
  }
}

# ── AWS Client VPN ────────────────────────────────────────────────────────────

run "client_vpn_with_byo_certs_creates_one_module_instance" {
  command = plan

  variables {
    enable_client_vpn          = true
    client_vpn_server_cert_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    client_vpn_root_cert_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
  }

  assert {
    condition     = length(module.client_vpn) == 1
    error_message = "Exactly one client_vpn module instance should be created when enable_client_vpn = true"
  }
}

run "client_vpn_with_generated_certs_creates_one_module_instance" {
  command = plan

  variables {
    enable_client_vpn              = true
    client_vpn_create_certificates = true
    client_vpn_client_names        = ["alice", "bob"]
  }

  assert {
    condition     = length(module.client_vpn) == 1
    error_message = "Exactly one client_vpn module instance should be created when enable_client_vpn = true and create_certificates = true"
  }
}

run "client_vpn_disabled_creates_no_instance" {
  command = plan

  variables {
    enable_client_vpn = false
  }

  assert {
    condition     = length(module.client_vpn) == 0
    error_message = "No client_vpn module instance should exist when enable_client_vpn = false"
  }
}

# ── Databricks VPC peering ────────────────────────────────────────────────────

run "peering_creates_connection_and_route" {
  command = plan

  variables {
    enable_databricks_peering = true
    databricks_vpc_id         = "vpc-0123456789abcdef0"
    databricks_vpc_cidr       = "10.1.0.0/16"
  }

  assert {
    condition     = length(aws_vpc_peering_connection.databricks) == 1
    error_message = "One peering connection should be created when enable_databricks_peering = true"
  }

  assert {
    condition     = length(aws_route.to_databricks) == 1
    error_message = "One peering route should be created when enable_databricks_peering = true"
  }
}

run "peering_disabled_creates_no_resources" {
  command = plan

  variables {
    enable_databricks_peering = false
  }

  assert {
    condition     = length(aws_vpc_peering_connection.databricks) == 0
    error_message = "No peering connection should exist when enable_databricks_peering = false"
  }
}

# ── Name prefix propagation ───────────────────────────────────────────────────

run "name_prefix_applied_to_seeder_sg" {
  command = plan

  variables {
    name_prefix = "myapp"
  }

  assert {
    condition     = aws_security_group.seeder_lambda.tags.Name == "myapp-seeder-sg"
    error_message = "Seeder SG Name tag should incorporate the name_prefix"
  }
}
