# Public IP changes each time the instance is stopped and restarted.
# Re-run `terraform output bastion_public_ip` after starting the instance
# to get the current address.
output "public_ip" {
  description = "Current public IP of the bastion host."
  value       = aws_instance.bastion.public_ip
}

# Use this ID to start/stop the bastion without going to the console:
#   aws ec2 start-instances  --instance-ids <id>
#   aws ec2 stop-instances   --instance-ids <id>
output "instance_id" {
  description = "EC2 instance ID of the bastion."
  value       = aws_instance.bastion.id
}

# Passed to modules/rds as an additional allowed_security_group_id so the
# bastion can reach the RDS port without opening a broad CIDR rule.
output "security_group_id" {
  description = "Security group ID attached to the bastion."
  value       = aws_security_group.bastion.id
}
