variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC to associate the VPN endpoint with."
  type        = string
}

# Used for the authorization rule (allowing clients to reach the VPC) and the
# route (directing VPC-bound traffic from the endpoint to the private subnets).
variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
}

# One ENI is placed per subnet. More subnets improve availability across AZs
# at $0.10/hr per association regardless of active connections.
variable "subnet_ids" {
  description = "Private subnets to associate with the VPN endpoint."
  type        = list(string)
}

# Must not overlap with the VPC CIDR or any other reachable CIDR. AWS allows
# /12–/22; /22 (~1,000 addresses) is sufficient for small-team dev access.
variable "client_cidr_block" {
  description = "CIDR block for VPN client IP addresses. Must not overlap with var.vpc_cidr."
  type        = string
}

# When true, a CA, server cert, and one client cert per entry in client_names
# are generated using the tls provider and imported into ACM automatically.
# Private keys are stored in Terraform state — acceptable for dev/test, avoid
# for production. When false, provide server_certificate_arn and
# root_certificate_arn instead.
variable "create_certificates" {
  description = "Auto-generate and import ACM certificates via the tls provider. Private keys will be stored in Terraform state."
  type        = bool
  default     = false
}

# One certificate/key pair is generated per entry. Each name becomes the
# common name on that client's certificate, so individual access can be
# revoked by removing the name and running terraform apply.
# Ignored when create_certificates = false.
variable "client_names" {
  description = "Names of VPN clients to generate certificates for. One cert/key pair per entry when create_certificates = true."
  type        = list(string)
  default     = ["client"]

  validation {
    condition     = length(var.client_names) > 0
    error_message = "client_names must contain at least one entry."
  }
}

# Required when create_certificates = false. The server certificate authenticates
# the VPN endpoint to connecting clients, preventing MITM attacks.
variable "server_certificate_arn" {
  description = "ARN of the ACM certificate for the VPN server. Required when create_certificates = false."
  type        = string
  default     = null
}

# Required when create_certificates = false. Any client presenting a certificate
# signed by this CA is considered authenticated (mutual TLS).
variable "root_certificate_arn" {
  description = "ARN of the ACM CA certificate used to validate client certificates. Required when create_certificates = false."
  type        = string
  default     = null
}

# With split tunnel enabled (default), the VPN only carries traffic destined
# for the VPC CIDR — clients keep their normal internet path for everything
# else. Set false to route all client traffic through the VPN.
variable "split_tunnel" {
  description = "Route only VPC-bound traffic through the VPN (true) or all client traffic (false)."
  type        = bool
  default     = true
}

# When enabled, connection events (client connect/disconnect) are written to a
# CloudWatch log group named /${name_prefix}/client-vpn. This requires the
# CloudWatch Logs service to be reachable from the VPN endpoint (no extra VPC
# endpoint needed — it uses the public endpoint). Recommended for production.
variable "enable_connection_logging" {
  description = "Write VPN connection events to CloudWatch Logs for audit purposes. Recommended for production."
  type        = bool
  default     = false
}

# Pushed to VPN clients via the DHCP options in the client config. The VPC
# DNS resolver (VPC CIDR + 2) is used when this list is empty, which is
# sufficient for resolving private RDS hostnames.
variable "dns_servers" {
  description = "Custom DNS server IPs pushed to VPN clients (max 2). Defaults to VPC resolver when empty."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.dns_servers) <= 2
    error_message = "AWS Client VPN supports at most 2 DNS servers."
  }
}
