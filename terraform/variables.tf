variable "region" {
  description = "AWS region for all resources (ADR-001)."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project/resource naming prefix."
  type        = string
  default     = "jjs-project-3-de-portfolio"
}

variable "glue_database_name" {
  description = "Glue Data Catalog database name."
  type        = string
  default     = "nyc_tlc_project3"
}

variable "athena_bytes_scanned_cutoff" {
  description = "Per-query bytes-scanned cap for the Athena workgroup (min 10 MB)."
  type        = number
  default     = 1073741824
}

variable "athena_results_expiration_days" {
  description = "Lifecycle expiration (days) for objects under athena-results/."
  type        = number
  default     = 7
}

variable "budget_limit_usd" {
  description = "Monthly COST budget limit in USD."
  type        = string
  default     = "5"
}

variable "budget_notification_email" {
  description = "Email address that receives budget alarm notifications."
  type        = string
}
