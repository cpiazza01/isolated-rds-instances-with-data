# The VPC is the top-level network boundary for this stack. Private subnets
# have no internet route — RDS and the seeder Lambda are isolated from the
# public internet. When enable_public_subnets = true, an internet gateway and
# public subnets are added for the optional bastion host; private resources
# are unaffected. DNS hostnames and support are enabled so RDS endpoint
# hostnames resolve correctly within the VPC.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# One private subnet is created per availability zone. RDS subnet groups
# require coverage across at least two AZs, and spreading subnets across
# zones also lets the seeder Lambda have ENIs in multiple AZs for resilience.
#
# cidrsubnet(vpc_cidr, 8, index) slices /24 blocks out of the VPC's address
# space: index 0 → x.x.0.0/24, index 1 → x.x.1.0/24, etc. Using a newbits
# value of 8 on a /16 VPC gives 256 possible /24 subnets — plenty of room.
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}" }
}

# A route table with no routes beyond the implicit local VPC route. Because
# there is no 0.0.0.0/0 route pointing to an internet gateway or NAT gateway,
# traffic is confined within the VPC. All subnets share this single table
# since they have identical routing requirements.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-private-rt" }
}

# Associates every private subnet with the route table above. Without this
# association each subnet falls back to the VPC's default (implicit) route
# table, which is fine but could be modified externally without Terraform
# knowing. Explicit associations give Terraform full ownership of routing.
resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Public subnets + internet gateway (optional) ─────────────────────────────
# Created only when var.enable_public_subnets = true (i.e. when a bastion host
# is enabled). Resources that should remain private (RDS, Lambda) continue to
# live exclusively in the private subnets defined above.

# The internet gateway is what gives public subnets their internet route.
# A VPC can have at most one IGW; count ensures it is skipped entirely when
# public subnets are not needed.
resource "aws_internet_gateway" "main" {
  count = var.enable_public_subnets ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-igw" }
}

# Public subnets occupy CIDR indices 100, 101, ... to leave the lower indices
# free for private subnets even if more AZs are added later.
resource "aws_subnet" "public" {
  count = var.enable_public_subnets ? length(var.availability_zones) : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 100 + count.index)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}" }
}

# A dedicated route table for public subnets. The 0.0.0.0/0 → IGW route is
# what makes a subnet "public" in AWS — without it, outbound internet traffic
# from instances in the subnet has nowhere to go.
resource "aws_route_table" "public" {
  count = var.enable_public_subnets ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = var.enable_public_subnets ? length(var.availability_zones) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# ── VPC endpoint — AWS Secrets Manager ───────────────────────────────────────
# Because this VPC has no NAT gateway, Lambda functions inside it cannot reach
# public AWS service endpoints by default. The seeder Lambda needs to call
# secretsmanager:GetSecretValue to retrieve the RDS master password at runtime.
#
# Cost: Interface VPC endpoints are billed at ~$0.01/hr per AZ (~$7/month per
# AZ, ~$14/month with two AZs) plus $0.01 per GB of data processed. This is
# cheaper than a NAT Gateway and is always created — it is not optional because
# the seeder Lambda cannot function without it in a fully private VPC.
#
# An interface VPC endpoint injects an ENI into each private subnet, giving
# Lambda (and any other resource in the VPC) a private network path to the
# Secrets Manager API without any traffic leaving the VPC boundary.
#
# private_dns_enabled = true means the standard regional endpoint hostname
# (secretsmanager.<region>.amazonaws.com) resolves to the private ENI IP
# inside the VPC, so no code changes are needed in the Lambda — boto3 just
# works with its default endpoint URL.

data "aws_region" "current" {}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-endpoints-"
  vpc_id      = aws_vpc.main.id
  description = "VPC interface endpoints — HTTPS from within VPC only"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from any resource in the VPC"
  }

  tags = { Name = "${var.name_prefix}-endpoints-sg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.id}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-secretsmanager-endpoint" }
}
