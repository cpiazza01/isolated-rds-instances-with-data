output "lambda_function_name" {
  description = "Name of the seeder Lambda function. Use with `aws lambda invoke` to re-seed without a full terraform apply."
  value       = aws_lambda_function.seeder.function_name
}
