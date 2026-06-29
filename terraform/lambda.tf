# Lambda: register_partition (ADR-007, ADR-010, ADR-011).
# Event-driven ingest, least-privilege execution role, boto3-only (no layer).

locals {
  lambda_function_name = "jjs-project-3-register-partition"
  lambda_role_name     = "jjs-project-3-lambda-exec"
}

data "archive_file" "register_partition" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/register_partition"
  output_path = "${path.module}/.lambda_build/register_partition.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name = local.lambda_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "jjs-project-3-lambda-exec-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_function_name}:*"
      },
      {
        Sid      = "ReadLanding"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/landing/*"
      },
      {
        Sid      = "WriteBronze"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data.arn}/bronze/*"
      },
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid    = "GluePartitions"
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreatePartition",
          "glue:BatchCreatePartition",
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.db.name}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.db.name}/${aws_glue_catalog_table.bronze_yellow_taxi.name}",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "register_partition" {
  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.register_partition.output_path
  source_code_hash = data.archive_file.register_partition.output_base64sha256

  environment {
    variables = {
      GLUE_DATABASE = aws_glue_catalog_database.db.name
      GLUE_TABLE    = aws_glue_catalog_table.bronze_yellow_taxi.name
    }
  }
}
