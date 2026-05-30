# VPC module unit tests. Targets ./modules/vpc directly via the module block.
#
# Run: terraform test -filter=tests/vpc.tftest.hcl

mock_provider "aws" {}

# ── Private subnets always present ───────────────────────────────────────────

run "private_subnets_always_created" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix        = "test"
    availability_zones = ["us-east-1a", "us-east-1b"]
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Should create one private subnet per AZ regardless of enable_public_subnets"
  }
}

run "private_subnets_scale_with_az_count" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix        = "test"
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "Private subnet count should match the number of availability zones"
  }
}

# ── Public resources absent by default ───────────────────────────────────────

run "no_igw_or_public_subnets_by_default" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix        = "test"
    availability_zones = ["us-east-1a", "us-east-1b"]
  }

  assert {
    condition     = length(aws_internet_gateway.main) == 0
    error_message = "Internet gateway should not be created when enable_public_subnets = false"
  }

  assert {
    condition     = length(aws_subnet.public) == 0
    error_message = "Public subnets should not be created when enable_public_subnets = false"
  }

  assert {
    condition     = length(aws_route_table.public) == 0
    error_message = "Public route table should not be created when enable_public_subnets = false"
  }
}

# ── Public resources created on demand ───────────────────────────────────────

run "igw_created_when_public_subnets_enabled" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix           = "test"
    availability_zones    = ["us-east-1a", "us-east-1b"]
    enable_public_subnets = true
  }

  assert {
    condition     = length(aws_internet_gateway.main) == 1
    error_message = "Exactly one internet gateway should be created when enable_public_subnets = true"
  }
}

run "public_subnets_match_az_count" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix           = "test"
    availability_zones    = ["us-east-1a", "us-east-1b"]
    enable_public_subnets = true
  }

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "Should create one public subnet per AZ when enable_public_subnets = true"
  }
}

run "public_subnets_use_high_cidr_indices" {
  command = plan

  module {
    source = "./modules/vpc"
  }

  variables {
    name_prefix           = "test"
    availability_zones    = ["us-east-1a", "us-east-1b"]
    vpc_cidr              = "10.0.0.0/16"
    enable_public_subnets = true
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.100.0/24"
    error_message = "First public subnet should use cidrsubnet index 100 (10.0.100.0/24), not overlap with private subnets"
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.0.0/24"
    error_message = "First private subnet should use cidrsubnet index 0 (10.0.0.0/24)"
  }
}
