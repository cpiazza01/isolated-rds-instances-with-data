output "vpc_id" {
  description = "ID of the VPC. Use when peering, attaching additional resources, or referencing the network boundary in IAM conditions."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (one per AZ). Pass to RDS subnet groups, Lambda vpc_config, and any other workload that should run inside the VPC."
  value       = aws_subnet.private[*].id
}

# Empty list when enable_public_subnets = false. The bastion module uses [0]
# but is itself guarded by count = 0, so the empty list is never dereferenced.
output "public_subnet_ids" {
  description = "IDs of the public subnets (one per AZ). Empty list when enable_public_subnets = false."
  value       = aws_subnet.public[*].id
}

# Exposed so the root module can add a peering route to this table without
# needing to reach inside the VPC module's internal resource graph.
output "private_route_table_id" {
  description = "ID of the private route table. Used by the root module to add peering routes (e.g. Databricks) without coupling to the VPC module's internals."
  value       = aws_route_table.private.id
}
