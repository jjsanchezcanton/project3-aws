# S3 -> Lambda event trigger (ADR-007). Permission must exist before the
# notification is created, or AWS rejects the notification config.
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3InvokeRegisterPartition"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.register_partition.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data.arn
}

resource "aws_s3_bucket_notification" "landing" {
  bucket = aws_s3_bucket.data.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.register_partition.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "landing/"
    filter_suffix       = ".parquet"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
