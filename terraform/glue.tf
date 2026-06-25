resource "aws_glue_catalog_database" "db" {
  name = var.glue_database_name
}
