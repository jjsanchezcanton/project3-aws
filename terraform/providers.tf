provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project_name
      managed_by = "terraform"
    }
  }
}
