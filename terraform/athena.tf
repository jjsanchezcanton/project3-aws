resource "aws_athena_workgroup" "wg" {
  name          = "${var.project_name}-wg"
  state         = "ENABLED"
  force_destroy = true # ← nivel raíz, no dentro de configuration

  configuration {
    enforce_workgroup_configuration    = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data.id}/athena-results/"
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
}
