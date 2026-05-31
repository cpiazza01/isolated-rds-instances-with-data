# Useful for CLI operations such as downloading the client configuration:
#   aws ec2 export-client-vpn-client-configuration \
#     --client-vpn-endpoint-id <id> --output text > client-config.ovpn
output "endpoint_id" {
  description = "ID of the Client VPN endpoint."
  value       = aws_ec2_client_vpn_endpoint.this.id
}

# The DNS name is embedded in the client configuration file that VPN users
# import into their VPN client software.
output "dns_name" {
  description = "DNS name of the Client VPN endpoint."
  value       = aws_ec2_client_vpn_endpoint.this.dns_name
}

# Passed to modules/rds as an additional allowed_security_group_id so
# authenticated VPN clients can reach the RDS port without a CIDR-based rule.
output "security_group_id" {
  description = "Security group ID attached to the VPN endpoint ENIs."
  value       = aws_security_group.this.id
}

# Map of client name → certificate PEM, one entry per name in client_names.
# Each certificate must be embedded in that user's .ovpn config file inside a
# <cert>...</cert> block so the VPN client can present it during the handshake.
# Empty map when create_certificates = false.
# Retrieve a specific cert: terraform output -json client_certificate_pem | jq -r '.alice'
output "client_certificate_pem" {
  description = "Map of client name to certificate PEM (empty when create_certificates = false). Embed each value in the corresponding user's .ovpn config file."
  sensitive   = true
  value       = { for name, cert in tls_locally_signed_cert.client : name => cert.cert_pem }
}

# Map of client name → private key PEM, one entry per name in client_names.
# Each key must be embedded in that user's .ovpn config file inside a
# <key>...</key> block. Keep these secret — anyone holding a key can
# authenticate to the VPN as that client. Revoke by removing the name from
# client_names and running terraform apply.
# Retrieve a specific key: terraform output -json client_private_key_pem | jq -r '.alice'
output "client_private_key_pem" {
  description = "Map of client name to private key PEM (empty when create_certificates = false). Embed each value in the corresponding user's .ovpn config file. Keep secret."
  sensitive   = true
  value       = { for name, key in tls_private_key.client : name => key.private_key_pem }
}

# Map of client name → Secrets Manager secret name. Each secret contains the
# cert+key block ready to append to client-config.ovpn. Empty when
# create_certificates = false.
output "client_ovpn_secret_names" {
  description = "Map of client name to Secrets Manager secret name containing the .ovpn cert+key append block (empty when create_certificates = false)."
  value       = { for name, s in aws_secretsmanager_secret.client_ovpn : name => s.name }
}
