# A combined MD5 hash of both the handler source and the requirements file.
# Used as the trigger value for terraform_data.build_package — when either
# file changes, the hash changes, which causes Terraform to re-run the pip
# install and produce a fresh Lambda deployment package.
locals {
  build_trigger = "${filemd5("${path.module}/lambda/seed.py")}-${filemd5("${path.module}/lambda/requirements.txt")}"
}

# ── IAM ───────────────────────────────────────────────────────────────────────

# Generates the trust policy document that allows the Lambda service to assume
# the execution role. This is separate from permissions — it only controls
# who is allowed to call sts:AssumeRole on the role, not what the role can do.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The IAM execution role that the Lambda function runs as. All AWS API calls
# made by the function are authorised against this role's attached policies.
# Using name_prefix instead of name lets AWS append a unique suffix, which
# prevents conflicts if the module is destroyed and reapplied quickly.
resource "aws_iam_role" "lambda" {
  name_prefix        = "${var.name_prefix}-seeder-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Attaches the AWS-managed VPC access policy to the execution role. This
# policy grants the permissions Lambda needs to create, describe, and delete
# the elastic network interfaces (ENIs) that connect the function to the VPC.
# Without it, Lambda cannot place ENIs in the private subnets and will fail
# to start when a vpc_config block is present.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Grants the Lambda permission to read the specific secret that RDS created for
# the master user password. The Resource is scoped to that single secret ARN
# rather than "*" so the function cannot access any other secrets in the account.
resource "aws_iam_role_policy" "read_db_secret" {
  name = "${var.name_prefix}-seeder-read-db-secret"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.db_secret_arn
      }
    ]
  })
}

# ── Build Lambda package ──────────────────────────────────────────────────────

# Runs scripts/build.py on the local machine whenever seed.py or
# requirements.txt changes. The script pip-installs the Python DB drivers
# (pg8000 / pymysql) and copies seed.py into lambda/package/, which is the
# directory that archive_file.lambda_zip then zips up.
#
# terraform_data is a built-in resource (no null provider needed) that
# replaces null_resource for local-exec provisioners. triggers_replace causes
# replacement — and re-runs the provisioner — when any listed value changes.
resource "terraform_data" "build_package" {
  triggers_replace = [local.build_trigger]

  provisioner "local-exec" {
    command = "python \"${path.module}/scripts/build.py\" \"${path.module}\""
  }
}

# Zips the contents of lambda/package/ into a single archive that can be
# uploaded to Lambda. `depends_on` defers this data source to apply time
# (Terraform 1.3+), ensuring it always runs *after* terraform_data.build_package
# has populated the package directory with the freshly installed dependencies.
# The .gitkeep placeholder file is excluded so it doesn't appear in the package.
data "archive_file" "lambda_zip" {
  depends_on  = [terraform_data.build_package]
  type        = "zip"
  source_dir  = "${path.module}/lambda/package"
  output_path = "${path.module}/lambda_package.zip"
  excludes    = [".gitkeep"]
}

# ── Lambda function ───────────────────────────────────────────────────────────

# The Lambda function that seeds the RDS instance with dummy data. Important
# configuration decisions:
#
#   runtime = "python3.12"  — matches the Python version assumed by seed.py
#     and the pip-installed packages. Changing this may require rebuilding the
#     package if any dependencies include compiled C extensions.
#
#   timeout = 900  — the maximum Lambda allows (15 minutes). Seeding large
#     row counts can be slow; 900 s gives headroom for up to ~500 k rows.
#
#   memory_size = 512  — more memory also gives the function proportionally
#     more CPU, which speeds up the Python loop that generates random rows.
#
#   vpc_config  — places the function inside the private VPC so it can reach
#     the RDS endpoint. Lambda injects an ENI into each listed subnet and
#     attaches the provided security group to that ENI.
#
#   source_code_hash  — tells Terraform to re-upload the zip whenever its
#     content changes, even if the filename stays the same.
resource "aws_lambda_function" "seeder" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "${var.name_prefix}-seeder"
  role             = aws_iam_role.lambda.arn
  handler          = "seed.handler"
  runtime          = "python3.12"
  timeout          = 900
  memory_size      = 512

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  # All DB connection details and the target row count are injected as
  # environment variables rather than hard-coded into the handler. This lets
  # the same Lambda binary be reused across different environments simply by
  # updating these values.
  environment {
    variables = {
      DB_ENGINE = var.db_engine
      DB_HOST   = var.db_host
      DB_PORT   = tostring(var.db_port)
      DB_NAME   = var.db_name
      DB_USER      = var.db_username
      DB_SECRET_ARN = var.db_secret_arn
      ROW_COUNT    = tostring(var.row_count)
    }
  }

  tags = { Name = "${var.name_prefix}-seeder" }
}

# ── Invoke seeder after RDS is ready ─────────────────────────────────────────

# Synchronously invokes the Lambda function once the RDS instance is up and
# the Lambda code has been deployed. The `aws lambda invoke` CLI call blocks
# until the function returns, so Terraform waits for seeding to complete
# before marking the apply as finished.
#
# The response payload is written to invoke_response.json in the module
# directory for post-apply inspection (e.g. to confirm the row count).
#
# Triggers are set so this resource is re-created — and the Lambda re-invoked
# — whenever any of the following change:
#   • row_count     : the caller wants a different number of rows
#   • db_instance   : the RDS instance was replaced (new instance = fresh seed)
#   • function_name : the Lambda itself was replaced
#   • lambda_hash   : the handler code or its dependencies changed
resource "terraform_data" "invoke_seeder" {
  # Re-runs when row count changes, RDS is replaced, or Lambda code changes.
  triggers_replace = [
    var.row_count,
    var.db_instance_id,
    aws_lambda_function.seeder.function_name,
    data.archive_file.lambda_zip.output_base64sha256,
  ]

  provisioner "local-exec" {
    # Invoke the Lambda synchronously, then validate the response with
    # check_response.py. aws lambda invoke exits 0 even on Lambda-side errors
    # (FunctionError is in the JSON, not the process exit code), so the second
    # command surfaces those failures and fails the apply immediately.
    command = "aws lambda invoke --function-name ${aws_lambda_function.seeder.function_name} --region ${var.aws_region} \"${path.module}/invoke_response.json\" && python \"${path.module}/scripts/check_response.py\" \"${path.module}/invoke_response.json\""
  }
}
