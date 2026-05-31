# ── Certificate generation (optional) ────────────────────────────────────────
#
# When create_certificates = true, a full PKI is generated here using the tls
# provider: a self-signed CA, a server cert signed by that CA, and a client
# cert signed by that CA. Both the server cert and the CA cert are imported into
# ACM so the VPN endpoint can reference them.
#
# WARNING: the tls provider stores private key PEM in Terraform state. Anyone
# with read access to the state file can extract the CA and client private keys.
# This is acceptable for ephemeral dev/test environments where state is already
# access-controlled. Use create_certificates = false and BYO certs for anything
# production-grade.
#
# Validity is set to 10 years to avoid surprise expiry for long-running stacks.

# The CA private key is the root of trust for this PKI. It signs both the
# server cert and any client certs, so possession of this key allows issuing
# new certificates that the VPN endpoint will accept.
resource "tls_private_key" "ca" {
  count     = var.create_certificates ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# The self-signed CA certificate is imported into ACM as the
# root_certificate_chain_arn — the VPN endpoint uses it to validate that
# connecting clients hold a certificate signed by this CA (mutual TLS).
resource "tls_self_signed_cert" "ca" {
  count             = var.create_certificates ? 1 : 0
  private_key_pem   = tls_private_key.ca[0].private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "${var.name_prefix}-vpn-ca"
    organization = var.name_prefix
  }

  validity_period_hours = 87600 # 10 years

  allowed_uses = ["cert_signing", "crl_signing"]
}

# The server private key is used to sign the server TLS certificate that the
# VPN endpoint presents to connecting clients during the handshake.
resource "tls_private_key" "server" {
  count     = var.create_certificates ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# The CSR carries the server's identity (common name) and public key to the CA
# so the CA can sign it and produce the final server certificate.
# dns_names adds a Subject Alternative Name matching the common name — AWS ACM
# requires at least one SAN (domain) on the server certificate when it is used
# with Client VPN, even for self-signed PKI.
resource "tls_cert_request" "server" {
  count           = var.create_certificates ? 1 : 0
  private_key_pem = tls_private_key.server[0].private_key_pem

  subject {
    common_name  = "${var.name_prefix}-vpn-server"
    organization = var.name_prefix
  }

  dns_names = ["${var.name_prefix}-vpn-server"]
}

# The CA-signed server certificate is what the VPN endpoint presents to clients
# during the TLS handshake. Clients verify it against the CA cert to confirm
# they are talking to the right endpoint (prevents MITM).
resource "tls_locally_signed_cert" "server" {
  count              = var.create_certificates ? 1 : 0
  cert_request_pem   = tls_cert_request.server[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 87600

  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

# One private key per client name. Each key is the credential that the
# corresponding user embeds in their .ovpn file — it proves they hold the
# private half of the key pair whose public half is in their client cert.
# Using for_each (keyed by name) means removing a name from client_names and
# re-applying destroys only that user's key and cert, revoking their access
# without touching any other client.
resource "tls_private_key" "client" {
  for_each  = toset(var.create_certificates ? var.client_names : [])
  algorithm = "RSA"
  rsa_bits  = 2048
}

# One CSR per client name. The CSR carries the client's identity (common name
# derived from the entry in client_names) to the CA so it can be signed into a
# certificate that the VPN endpoint will recognise as valid.
resource "tls_cert_request" "client" {
  for_each        = toset(var.create_certificates ? var.client_names : [])
  private_key_pem = tls_private_key.client[each.key].private_key_pem

  subject {
    common_name  = "${var.name_prefix}-vpn-${each.key}"
    organization = var.name_prefix
  }
}

# One CA-signed client certificate per client name. Each certificate is
# embedded in that user's .ovpn file. The VPN endpoint verifies it against the
# CA cert (root_certificate_chain_arn) to authenticate the client without a
# username or password.
resource "tls_locally_signed_cert" "client" {
  for_each           = toset(var.create_certificates ? var.client_names : [])
  cert_request_pem   = tls_cert_request.client[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 87600

  allowed_uses = ["key_encipherment", "digital_signature", "client_auth"]
}

# Imports the server cert (plus its CA chain) into ACM so the VPN endpoint
# resource can reference it by ARN. ACM stores the private key on AWS-managed
# infrastructure; the copy in Terraform state is the security trade-off noted
# above.
resource "aws_acm_certificate" "server" {
  count             = var.create_certificates ? 1 : 0
  private_key       = tls_private_key.server[0].private_key_pem
  certificate_body  = tls_locally_signed_cert.server[0].cert_pem
  certificate_chain = tls_self_signed_cert.ca[0].cert_pem

  tags = { Name = "${var.name_prefix}-vpn-server-cert" }
}

# Imports the CA certificate into ACM so the VPN endpoint can use its ARN as
# root_certificate_chain_arn — the trust anchor for validating client certs.
resource "aws_acm_certificate" "ca" {
  count            = var.create_certificates ? 1 : 0
  private_key      = tls_private_key.ca[0].private_key_pem
  certificate_body = tls_self_signed_cert.ca[0].cert_pem

  tags = { Name = "${var.name_prefix}-vpn-ca-cert" }
}

# ── Client credential secrets ────────────────────────────────────────────────

# Stores each client's cert + key as a single Secrets Manager secret so users
# can append it to their .ovpn file with one AWS CLI call — no jq or terraform
# access needed. The SecretString is the exact text to append to client-config.ovpn.
# Only created when create_certificates = true; BYO-cert users manage their own
# key material outside Terraform.
resource "aws_secretsmanager_secret" "client_ovpn" {
  for_each    = toset(var.create_certificates ? var.client_names : [])
  name        = "${var.name_prefix}-vpn-${each.key}-ovpn"
  description = "Client VPN cert and key for ${each.key}. Append SecretString directly to client-config.ovpn."
  tags        = { Name = "${var.name_prefix}-vpn-${each.key}-ovpn" }
}

# Stores the actual cert and key PEM values. Written as a separate resource so
# Terraform can update the value independently of the secret metadata.
resource "aws_secretsmanager_secret_version" "client_ovpn" {
  for_each  = toset(var.create_certificates ? var.client_names : [])
  secret_id = aws_secretsmanager_secret.client_ovpn[each.key].id
  secret_string = "<cert>\n${tls_locally_signed_cert.client[each.key].cert_pem}</cert>\n<key>\n${tls_private_key.client[each.key].private_key_pem}</key>\n"
}

# ── Connection logging (optional) ────────────────────────────────────────────

# Created only when enable_connection_logging = true. Stores one log stream per
# connection event (connect/disconnect) so operators can audit who used the VPN
# and when. The log group is retained indefinitely by default; set a retention
# policy manually if log storage costs are a concern.
resource "aws_cloudwatch_log_group" "client_vpn" {
  count             = var.enable_connection_logging ? 1 : 0
  name              = "/${var.name_prefix}/client-vpn"
  retention_in_days = 90
  tags              = { Name = "${var.name_prefix}-client-vpn-logs" }
}

# ── Security group ────────────────────────────────────────────────────────────

# Security group attached to the VPN endpoint's ENIs in each associated subnet.
# The RDS security group references this SG ID as an allowed source, so
# traffic from authenticated VPN clients is permitted on the DB port without
# opening it to a broad CIDR range.
#
# No ingress rules are needed here — inbound TLS (port 443) is handled by
# the managed VPN endpoint infrastructure, not this SG.
resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-client-vpn-"
  vpc_id      = var.vpc_id
  description = "AWS Client VPN endpoint - allows authenticated clients to reach VPC resources"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "All outbound to VPC"
  }

  tags = { Name = "${var.name_prefix}-client-vpn-sg" }

  lifecycle { create_before_destroy = true }
}

# ── VPN endpoint ──────────────────────────────────────────────────────────────

# The Client VPN endpoint is the AWS-managed TLS termination point. Clients
# connect using the AWS VPN Client app (or any OpenVPN-compatible client) and
# present a certificate signed by the CA. The endpoint verifies the client cert
# against root_certificate_chain_arn, then allows access per the authorization
# rules below.
#
# server_certificate_arn and root_certificate_chain_arn are either the
# auto-generated ACM imports (create_certificates = true) or BYO ARNs supplied
# via variables — the precondition below enforces that one path is taken.
#
# split_tunnel = true (default) routes only traffic destined for the VPC CIDR
# through the VPN; all other client internet traffic exits normally, reducing
# latency and data-transfer costs.
resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "${var.name_prefix} client VPN"
  client_cidr_block      = var.client_cidr_block
  split_tunnel           = var.split_tunnel
  vpc_id                 = var.vpc_id
  security_group_ids     = [aws_security_group.this.id]
  dns_servers            = length(var.dns_servers) > 0 ? var.dns_servers : null
  server_certificate_arn = var.create_certificates ? aws_acm_certificate.server[0].arn : var.server_certificate_arn

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.create_certificates ? aws_acm_certificate.ca[0].arn : var.root_certificate_arn
  }

  connection_log_options {
    enabled               = var.enable_connection_logging
    cloudwatch_log_group  = var.enable_connection_logging ? aws_cloudwatch_log_group.client_vpn[0].name : null
    cloudwatch_log_stream = var.enable_connection_logging ? "${var.name_prefix}-connections" : null
  }

  tags = { Name = "${var.name_prefix}-client-vpn" }

  lifecycle {
    precondition {
      condition     = var.create_certificates || (var.server_certificate_arn != null && var.root_certificate_arn != null)
      error_message = "When create_certificates = false, both server_certificate_arn and root_certificate_arn must be provided."
    }
  }
}

# ── Network associations ──────────────────────────────────────────────────────

# Each association places a VPN endpoint ENI into the target subnet, enabling
# clients to route traffic into that subnet's AZ. AWS recommends one
# association per AZ for high availability; each costs $0.10/hr regardless of
# whether any clients are connected.
resource "aws_ec2_client_vpn_network_association" "this" {
  count = length(var.subnet_ids)

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = var.subnet_ids[count.index]
}

# ── Authorization rule ────────────────────────────────────────────────────────

# AWS Client VPN enforces a two-layer access model: authentication (is this a
# valid certificate?) and authorization (is this client allowed to reach this
# network?). This rule grants all authenticated clients access to the full VPC
# CIDR. Without it, clients can connect to the VPN but cannot reach anything.
resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Allow all authenticated VPN clients to reach VPC resources"
}
