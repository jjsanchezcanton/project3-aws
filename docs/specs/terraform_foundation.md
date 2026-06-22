# Spec — Terraform foundation (Milestone A)

**Component:** `terraform/` — the foundational AWS infrastructure for Project 3.
**Drives:** Milestone A acceptance gate ("`terraform apply` provisions infra from clean clone; Budget alarm active").
**Read first:** `CLAUDE.md`, ADR-001 (region), ADR-002 (serverless/free-tier + guardrails), ADR-003 (Athena warehouse).
**Workflow reminder:** summarise your understanding and list ambiguities before writing any `.tf`. Author reviews every file line by line before `terraform apply`.

## Objective

Provision, with Terraform 1.15.x and `hashicorp/aws ~> 6.0`, the minimal AWS foundation for the pipeline:
1. One S3 data-lake bucket (account-ID-suffixed name).
2. One Glue Catalog database.
3. One Athena workgroup with a **per-query bytes-scanned cap** and a results location.
4. One AWS Budget with email alarms.

IAM users/roles are **out of scope here**: the dev IAM user is created manually by the author (see Appendix A); the Lambda execution role comes in Milestone B.

## Constraints

- Region **eu-west-2**, as a variable (ADR-001).
- **Local** Terraform backend for now (solo portfolio); `terraform.tfstate*` git-ignored. (Remote S3 backend is a possible later enhancement, not now.)
- Bucket name globally unique: `"${var.project_name}-${data.aws_caller_identity.current.account_id}"` — **account ID suffix** (confirmed decision; stable + reproducible).
- Security: block all public access, SSE-S3 encryption, `enforce_workgroup_configuration = true` so the bytes cap cannot be overridden client-side.
- `force_destroy = true` on the bucket so `terraform destroy` is clean for a portfolio (documents that this deletes objects — acceptable here).
- Default tags on the provider: `{ project = var.project_name, managed_by = "terraform" }`.

## File layout (`terraform/`)

```
terraform/
├── versions.tf            # required_version >= 1.15, required_providers aws ~> 6.0
├── providers.tf           # provider "aws" { region = var.region, default_tags {...} }
├── data.tf                # data "aws_caller_identity" "current" {}
├── s3.tf                  # bucket + public-access-block + SSE + lifecycle
├── glue.tf                # aws_glue_catalog_database
├── athena.tf              # aws_athena_workgroup
├── budget.tf              # aws_budgets_budget
├── variables.tf
├── outputs.tf
└── terraform.tfvars.example
```

## Variables (`variables.tf`)

| Variable | Type | Default | Notes |
|---|---|---|---|
| `region` | string | `"eu-west-2"` | ADR-001 |
| `project_name` | string | `"jjs-project-3-de-portfolio"` | bucket/workgroup/budget name prefix |
| `glue_database_name` | string | `"nyc_tlc_project3"` | Glue catalog DB |
| `athena_bytes_scanned_cutoff` | number | `1073741824` | 1 GB cap per query (min allowed 10 MB) |
| `athena_results_expiration_days` | number | `7` | lifecycle expiry for `athena-results/` |
| `budget_limit_usd` | string | `"5"` | monthly COST budget |
| `budget_notification_email` | string | — (required, set in tfvars) | alarm recipient |

`terraform.tfvars.example` lists every variable with placeholder values (especially `budget_notification_email = "you@example.com"`). The real `terraform.tfvars` is git-ignored.

## Resource details

### S3 (`s3.tf`)
- `aws_s3_bucket` "data" — name `"${var.project_name}-${data.aws_caller_identity.current.account_id}"`, `force_destroy = true`.
- `aws_s3_bucket_public_access_block` — all four flags `true`.
- `aws_s3_bucket_server_side_encryption_configuration` — `sse_algorithm = "AES256"` (SSE-S3, free).
- `aws_s3_bucket_lifecycle_configuration` — two rules:
  - expire objects under prefix `athena-results/` after `var.athena_results_expiration_days`.
  - abort incomplete multipart uploads after 7 days.
- Do **not** create prefix "folders" as resources — `landing/`, `bronze/`, `silver/`, `gold/`, `athena-results/` are just key prefixes used by later code.

### Glue (`glue.tf`)
- `aws_glue_catalog_database` "db" — name `var.glue_database_name`.

### Athena (`athena.tf`)
- `aws_athena_workgroup` "wg" — name `"${var.project_name}-wg"`, `state = "ENABLED"`, `force_destroy = true`, with `configuration`:
  - `enforce_workgroup_configuration = true`
  - `bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff`
  - `publish_cloudwatch_metrics_enabled = true`
  - `result_configuration { output_location = "s3://<data bucket>/athena-results/" }`
  - `engine_version { selected_engine_version = "Athena engine version 3" }`

### Budget (`budget.tf`)
- `aws_budgets_budget` "monthly" — `budget_type = "COST"`, `limit_amount = var.budget_limit_usd`, `limit_unit = "USD"`, `time_unit = "MONTHLY"`.
- Two `notification` blocks (both `GREATER_THAN`, `PERCENTAGE`, subscriber = `var.budget_notification_email`):
  - `threshold = 80`, `notification_type = "ACTUAL"`
  - `threshold = 100`, `notification_type = "FORECASTED"`

### Outputs (`outputs.tf`)
- `data_bucket_name`, `glue_database_name`, `athena_workgroup_name`, `athena_results_location` (full `s3://.../athena-results/` URI — dbt-athena's `s3_staging_dir` will use this in Milestone C).

## Acceptance asserts

Run from `terraform/` with the dev profile active:
1. `terraform init` succeeds; `terraform fmt -check` and `terraform validate` pass.
2. `terraform plan` shows exactly: 1 bucket (+ its config resources), 1 Glue DB, 1 Athena workgroup, 1 Budget. Bucket name ends in the 12-digit account ID.
3. `terraform apply` succeeds. Then verify with the CLI:
   - `aws s3 ls | grep jjs-project-3-de-portfolio` → bucket present.
   - `aws glue get-database --name nyc_tlc_project3 --region eu-west-2` → returns the DB.
   - `aws athena get-work-group --work-group jjs-project-3-de-portfolio-wg --region eu-west-2` → `BytesScannedCutoffPerQuery` = 1073741824, `EnforceWorkGroupConfiguration` = true, engine v3.
   - `aws budgets describe-budgets --account-id <id>` → the monthly $5 budget present.
4. Smoke query: `aws athena start-query-execution --query-string "SELECT 1" --work-group jjs-project-3-de-portfolio-wg --region eu-west-2` → succeeds; result lands under `athena-results/`.
5. (Optional manual) a query that would scan > 1 GB fails with a bytes-cutoff error — proves the guardrail.
6. `terraform destroy` removes everything cleanly (force_destroy empties the bucket); a second `terraform plan` shows no resources.
7. No credentials anywhere in the repo; `terraform.tfstate*`, `.terraform/`, `*.tfvars` (except `.example`) are git-ignored.

## `.gitignore` additions (repo root)
```
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
.env
*.pem
__pycache__/
.venv*/
```

---

## Appendix A — Dev IAM user policy (you create this user manually)

Attach a least-privilege policy to the dev IAM user. A workable scoped policy for Milestone A (broaden minimally in later milestones for Lambda/Glue table ops):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "S3Bucket",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket","s3:DeleteBucket","s3:ListBucket","s3:GetBucket*","s3:PutBucket*","s3:DeleteBucketPolicy","s3:PutLifecycleConfiguration","s3:GetLifecycleConfiguration","s3:PutEncryptionConfiguration","s3:GetEncryptionConfiguration"],
      "Resource": "arn:aws:s3:::jjs-project-3-de-portfolio-*" },
    { "Sid": "S3Objects",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::jjs-project-3-de-portfolio-*/*" },
    { "Sid": "Glue",
      "Effect": "Allow",
      "Action": ["glue:*Database*","glue:*Table*","glue:*Partition*","glue:GetCatalog*"],
      "Resource": "*" },
    { "Sid": "Athena",
      "Effect": "Allow",
      "Action": ["athena:*","s3:GetBucketLocation"],
      "Resource": "*" },
    { "Sid": "Budgets",
      "Effect": "Allow",
      "Action": ["budgets:ViewBudget","budgets:ModifyBudget","budgets:CreateBudget","budgets:DescribeBudget*"],
      "Resource": "*" },
    { "Sid": "Identity",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity"],
      "Resource": "*" }
  ]
}
```

Notes / honesty flags:
- `glue:*` and `athena:*` are scoped by service rather than by resource (Glue/Athena resource-level scoping is awkward); acceptable for a solo portfolio account, and worth saying so in an interview ("I'd tighten these with resource ARNs and conditions in a shared account").
- Milestone B adds Lambda + an execution role, which needs `iam:CreateRole`/`PassRole` (broad). When we get there, ADR + policy will scope `PassRole` with a condition on the Lambda service. Flagged now so it isn't a surprise.
- Budgets actions are global (no region); everything else operates in eu-west-2.
