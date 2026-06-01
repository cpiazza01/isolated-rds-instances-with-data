# Client VPN module unit tests. Each run block uses `module { source = "..." }`
# to target ./modules/client_vpn directly so assertions run against that module's
# plan without going through the root module.
#
# Run: terraform test -filter=tests/client_vpn.tftest.hcl

mock_provider "aws" {}
mock_provider "tls" {}

# Shared variable defaults used across most runs. Required variables with no
# module-level default must be supplied in every run block.
variables {
  name_prefix       = "test"
  vpc_id            = "vpc-0123456789abcdef0"
  vpc_cidr          = "10.0.0.0/16"
  subnet_ids        = ["subnet-0000000000000001", "subnet-0000000000000002"]
  client_cidr_block = "172.16.0.0/22"
}

# ── BYO certificates ──────────────────────────────────────────────────────────

run "byo_certs_no_tls_resources_generated" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates    = false
    server_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
  }

  assert {
    condition     = length(tls_private_key.ca) == 0
    error_message = "No CA key should be generated when create_certificates = false"
  }

  assert {
    condition     = length(tls_private_key.client) == 0
    error_message = "No client keys should be generated when create_certificates = false"
  }

  assert {
    condition     = length(aws_acm_certificate.server) == 0
    error_message = "No ACM server cert should be imported when create_certificates = false"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.client_ovpn) == 0
    error_message = "No Secrets Manager secrets should be created when create_certificates = false"
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.client_ovpn) == 0
    error_message = "No Secrets Manager secret versions should be created when create_certificates = false"
  }
}

# ── Auto-generated certificates ───────────────────────────────────────────────

run "auto_certs_generates_ca_and_server" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates = true
    client_names        = ["alice"]
  }

  assert {
    condition     = length(tls_private_key.ca) == 1
    error_message = "One CA private key should be generated when create_certificates = true"
  }

  assert {
    condition     = length(tls_self_signed_cert.ca) == 1
    error_message = "One self-signed CA cert should be generated when create_certificates = true"
  }

  assert {
    condition     = length(aws_acm_certificate.server) == 1
    error_message = "One ACM server cert should be imported when create_certificates = true"
  }

  assert {
    condition     = length(aws_acm_certificate.ca) == 1
    error_message = "One ACM CA cert should be imported when create_certificates = true"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.client_ovpn) == 1
    error_message = "One Secrets Manager secret should be created per client when create_certificates = true"
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.client_ovpn) == 1
    error_message = "One Secrets Manager secret version should be created per client when create_certificates = true"
  }
}

run "client_names_controls_cert_count" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates = true
    client_names        = ["alice", "bob", "charlie"]
  }

  assert {
    condition     = length(tls_private_key.client) == 3
    error_message = "One client key should be generated per entry in client_names"
  }

  assert {
    condition     = length(tls_locally_signed_cert.client) == 3
    error_message = "One signed client cert should be generated per entry in client_names"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.client_ovpn) == 3
    error_message = "One Secrets Manager secret should be created per client name"
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.client_ovpn) == 3
    error_message = "One Secrets Manager secret version should be created per client name"
  }
}

# ── Network associations ──────────────────────────────────────────────────────

run "one_association_per_subnet" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates    = false
    server_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
    subnet_ids             = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
  }

  assert {
    condition     = length(aws_ec2_client_vpn_network_association.this) == 3
    error_message = "One network association should be created per subnet"
  }
}

# ── Split tunnel ──────────────────────────────────────────────────────────────

run "split_tunnel_enabled_by_default" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates    = false
    server_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.this.split_tunnel == true
    error_message = "Split tunnel should be enabled by default"
  }
}

# ── Connection logging ────────────────────────────────────────────────────────

run "logging_disabled_creates_no_log_group" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates       = false
    server_certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
    enable_connection_logging = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.client_vpn) == 0
    error_message = "No CloudWatch log group should be created when logging is disabled"
  }
}

run "logging_enabled_creates_log_group" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    create_certificates       = false
    server_certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
    enable_connection_logging = true
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.client_vpn) == 1
    error_message = "One CloudWatch log group should be created when logging is enabled"
  }

  assert {
    condition     = aws_cloudwatch_log_group.client_vpn[0].retention_in_days == 90
    error_message = "Log group should have 90-day retention"
  }
}

# ── Name prefix propagation ───────────────────────────────────────────────────

run "name_prefix_applied_to_resources" {
  command = plan

  module {
    source = "./modules/client_vpn"
  }

  variables {
    name_prefix            = "myapp"
    create_certificates    = false
    server_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
    root_certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
  }

  assert {
    condition     = aws_security_group.this.tags.Name == "myapp-client-vpn-sg"
    error_message = "Security group Name tag should incorporate the name_prefix"
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.this.tags.Name == "myapp-client-vpn"
    error_message = "VPN endpoint Name tag should incorporate the name_prefix"
  }
}
