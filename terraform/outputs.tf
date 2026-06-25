output "data_bucket_name" {
  description = "Name of the S3 data-lake bucket."
  value       = aws_s3_bucket.data.id
}

output "glue_database_name" {
  description = "Name of the Glue Data Catalog database."
  value       = aws_glue_catalog_database.db.name
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup."
  value       = aws_athena_workgroup.wg.name
}

output "athena_results_location" {
  description = "S3 URI used as the Athena workgroup result location."
  value       = "s3://${aws_s3_bucket.data.id}/athena-results/"
}
