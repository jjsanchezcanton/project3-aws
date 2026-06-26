# Spec — Ingestion + event-driven Lambda + Bronze table (Milestone B)

**Components:** `ingestion/`, `lambda/register_partition/`, and a Bronze `aws_glue_catalog_table` added to `terraform/`.
**Drives:** Milestone B gate — "uploading to `landing/` auto-registers the Bronze partition; `SELECT count(*)` in Athena returns ~2.96M".
**Read first:** `CLAUDE.md`, ADRs 001–006, and ADRs 007–011 in this spec (append them to `docs/decisions.md`).
**Workflow reminder:** summarise understanding + list ambiguities before writing code. Author reviews line by line.

> ⚠️ **Do the IAM policy update in Appendix A *before* `terraform apply`.** Creating the Lambda and its role needs permissions the dev user does not have yet; skipping this reproduces the mid-apply `AccessDenied` we hit in Milestone A.

## Objective

Land one month of NYC TLC Yellow Taxi data into S3 and make it queryable in Athena as a partitioned Bronze external table, using an **event-driven** ingest: an upload to `landing/` triggers a Lambda that validates the file, promotes it to the Bronze partition path, and registers the partition in the Glue Data Catalog. No crawler, no manual DDL run.

## Data + flow

- Source: `https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2024-01.parquet` (~50 MB, ~2.96M rows — same partition as Project 1).
- Flow:
  1. `download_tlc.py` → local `data/yellow_tripdata_2024-01.parquet` (idempotent).
  2. `upload_to_landing.py` → `s3://<bucket>/landing/yellow_tripdata_2024-01.parquet` (boto3 PUT).
  3. S3 `ObjectCreated` event (prefix `landing/`, suffix `.parquet`) → **Lambda `register_partition`**.
  4. Lambda: validate → CopyObject to `s3://<bucket>/bronze/yellow_taxi/year=2024/month=01/yellow_tripdata_2024-01.parquet` → `glue:CreatePartition`.
  5. Athena: `SELECT count(*) FROM nyc_tlc_project3.bronze_yellow_taxi` → ~2.96M.

S3 key conventions:
- landing: `landing/yellow_tripdata_<YYYY>-<MM>.parquet`
- bronze table root: `s3://<bucket>/bronze/yellow_taxi/`
- bronze partition: `.../year=<YYYY>/month=<MM>/` (zero-padded month, matching Project 1)

## Constraints

- Lambda runtime **Python 3.12, boto3 only** (boto3 ships in the runtime → no layer, no packaging deps → free, fast). The Lambda does **not** parse parquet content (ADR-011).
- Partition keys `year string, month string` (string avoids int/zero-pad ambiguity; path uses `month=01`).
- Idempotent end to end: re-upload overwrites the object; `CreatePartition` on an existing partition is caught and treated as success.
- Region eu-west-2; names prefixed `jjs-project-3-*`.
- Credentials from `~/.aws` profile / env only; nothing committed.

## New file layout

```
ingestion/
├── download_tlc.py          # download source parquet, idempotent (size/MD5 guard)
└── upload_to_landing.py     # boto3 PUT to landing/ (reads bucket from env)
lambda/
└── register_partition/
    └── handler.py           # S3 event → validate → copy → glue:CreatePartition
terraform/
├── glue_tables.tf           # aws_glue_catalog_table.bronze_yellow_taxi (NEW)
├── lambda.tf                # archive_file + aws_lambda_function + role + policy (NEW)
└── s3_notification.tf       # aws_s3_bucket_notification + aws_lambda_permission (NEW)
sql/ddl/
└── bronze_yellow_taxi.sql   # readable CREATE EXTERNAL TABLE equivalent (doc only; Terraform is source of truth)
.env.example                 # add DATA_BUCKET, AWS_REGION
```

## Component specs

### 1. Bronze Glue table — `terraform/glue_tables.tf`

`aws_glue_catalog_table` "bronze_yellow_taxi", database = `aws_glue_catalog_database.db.name`, `table_type = "EXTERNAL_TABLE"`.
- `partition_keys`: `year` (string), `month` (string).
- `storage_descriptor`:
  - `location = "s3://${aws_s3_bucket.data.bucket}/bronze/yellow_taxi/"`
  - `input_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"`
  - `output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"`
  - `ser_de_info` → `serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"`
  - `columns` (recommended types below).
- `parameters = { classification = "parquet", "parquet.compression" = "SNAPPY" }`.

**Recommended columns** (⚠️ verify against the real file before finalising — see note):
```
vendorid bigint · tpep_pickup_datetime timestamp · tpep_dropoff_datetime timestamp ·
passenger_count double · trip_distance double · ratecodeid double · store_and_fwd_flag string ·
pulocationid bigint · dolocationid bigint · payment_type bigint · fare_amount double ·
extra double · mta_tax double · tip_amount double · tolls_amount double ·
improvement_surcharge double · total_amount double · congestion_surcharge double · airport_fee double
```
**Schema-verification step (required):** TLC files drift across months (notably `passenger_count`/`ratecodeid` stored as double, and `Airport_fee` casing). Before writing the final DDL, inspect the downloaded file and match names/types exactly:
```bash
python -c "import pyarrow.parquet as pq; print(pq.read_schema('data/yellow_tripdata_2024-01.parquet'))"
```
The `SELECT * LIMIT 10` assert will surface any mismatch (NULLs in every row of a column = wrong type/name). Glue lowercases column names; declare them lowercase.

Mirror the same definition as readable SQL in `sql/ddl/bronze_yellow_taxi.sql` with a header comment: *"Documentation only — source of truth is terraform/glue_tables.tf."*

### 2. `ingestion/download_tlc.py`
- Download the source URL to `data/yellow_tripdata_2024-01.parquet`.
- Idempotent: if the file exists and its size matches the remote `Content-Length` (HEAD), skip; else (re)download. Log a short summary (path, bytes).
- Stdlib + `requests` (or `urllib`). No AWS needed.
- CLI args optional (`--year 2024 --month 1`), defaulting to 2024-01.

### 3. `ingestion/upload_to_landing.py`
- Read `DATA_BUCKET` and `AWS_REGION` from env (`.env`, populated from `terraform output`).
- boto3 `s3.upload_file(local, bucket, "landing/yellow_tripdata_2024-01.parquet")`.
- Print the object key + ETag on success. Idempotent (overwrites).
- This PUT is what fires the Lambda — no other trigger.

### 4. Lambda `register_partition` — `lambda/register_partition/handler.py` + Terraform

**Handler logic:**
1. For each S3 record: read `bucket`, `key` (URL-decode the key).
2. Validate: `key` matches `^landing/yellow_tripdata_(\d{4})-(\d{2})\.parquet$`; `HeadObject` size > 0. If invalid, log and skip (don't raise — avoids poison retries).
3. Derive `year`, `month` from the regex groups.
4. `CopyObject` → `bronze/yellow_taxi/year=<year>/month=<month>/<filename>` (same bucket, server-side copy).
5. `glue.get_table` (db, `bronze_yellow_taxi`) → take its `StorageDescriptor`, set `Location` to the partition S3 path → `glue.create_partition(PartitionInput=...)`. Catch `AlreadyExistsException` → log as idempotent no-op.
6. Log structured result (year, month, rows not computed here, partition location). Return 200.

Keep it dependency-light: `import boto3, re, urllib.parse, json, logging` only.

**Terraform — `lambda.tf`:**
- `data "archive_file"` zips `lambda/register_partition/`.
- `aws_iam_role` "lambda_exec" (name `jjs-project-3-lambda-exec`), assume-role policy for `lambda.amazonaws.com`.
- `aws_iam_role_policy` (least-privilege execution policy):
  - `logs:CreateLogGroup/CreateLogStream/PutLogEvents` (CloudWatch).
  - `s3:GetObject` on `arn:.../landing/*`; `s3:PutObject` on `arn:.../bronze/*`; `s3:ListBucket` on the bucket.
  - `glue:GetTable`, `glue:GetPartition`, `glue:GetPartitions`, `glue:CreatePartition`, `glue:BatchCreatePartition` on the catalog/database/table ARNs.
- `aws_lambda_function` "register_partition": runtime `python3.12`, handler `handler.lambda_handler`, role = exec role, timeout 60, memory 128, `source_code_hash` from the archive, env var `GLUE_DATABASE = nyc_tlc_project3`.

**Terraform — `s3_notification.tf`:**
- `aws_lambda_permission` "allow_s3" — `action = "lambda:InvokeFunction"`, `principal = "s3.amazonaws.com"`, `source_arn = bucket ARN`.
- `aws_s3_bucket_notification` "landing" — `lambda_function { lambda_function_arn, events = ["s3:ObjectCreated:*"], filter_prefix = "landing/", filter_suffix = ".parquet" }`, with `depends_on = [aws_lambda_permission.allow_s3]` (the permission must exist first, or the notification create fails).

### 5. IAM — see Appendix A. Apply before `terraform apply`.

## Decisions (append to `docs/decisions.md`)

**ADR-007 — Event-driven ingest (Lambda + S3 events).** Ingest is triggered by the S3 `ObjectCreated` event on `landing/`, not a schedule or a poll. *Why:* reactive, decoupled, demonstrates the canonical AWS serverless ingest pattern; the orchestrated path (Airflow, Milestone D) drives the *deterministic* transform sequence — two complementary patterns. *When polling/scheduled would win:* sources that don't emit events, or strict batch windows where you want a single controlled trigger time.

**ADR-008 — Partition registration via Glue API in the Lambda, not a crawler, not partition projection.** *Why:* a crawler costs DPU-hours and is non-deterministic; partition projection is free but removes the event-driven registration that is the *point* of this milestone. Explicit `CreatePartition` is deterministic and free. *When projection would win:* large, regular, predictable partition layouts where you never want per-file logic — then projection beats both.

**ADR-009 — Bronze external table defined in Terraform (`aws_glue_catalog_table`), schema declared (not VARIANT).** *Why:* IaC source of truth, reproducible with the rest of the stack, removed by `terraform destroy`; Athena over parquet has no VARIANT, so the schema is declared, with a verification step against the real file to absorb TLC drift. A readable SQL mirror is committed as documentation. *When Athena DDL alone would win:* throwaway exploration where IaC overhead isn't justified.

**ADR-010 — Least-privilege Lambda execution role + scoped `PassRole`.** *Why:* the execution role can only read `landing/`, write `bronze/`, and manage partitions on the one table; the dev user's `iam:PassRole` is conditioned to `lambda.amazonaws.com` and role/policy management is ARN-scoped to `jjs-project-3-*`. *Interview point:* "I scoped PassRole with a service condition rather than granting `iam:PassRole` on `*`."

**ADR-011 — Lambda is dependency-light (boto3 only); no parquet parsing.** *Why:* validates by key pattern + object size, not content — avoids a heavy pyarrow layer, keeps cold starts and packaging trivial, stays free. Row-level validation belongs in the Silver dbt layer (Milestone C), not at ingest. *When content validation at ingest would win:* when malformed files must be rejected before landing and a schema/row check is cheap relative to downstream cost.

## Acceptance asserts

1. `python ingestion/download_tlc.py` downloads the file; a second run is a no-op (size guard).
2. `python ingestion/upload_to_landing.py` PUTs to `landing/`; `aws s3 ls s3://<bucket>/landing/` shows the object.
3. Within ~seconds, the Lambda fires (check CloudWatch: `aws logs tail /aws/lambda/jjs-project-3-register-partition --region eu-west-2`), and:
   - object copied: `aws s3 ls s3://<bucket>/bronze/yellow_taxi/year=2024/month=01/` shows the parquet.
   - partition registered: `aws glue get-partitions --database-name nyc_tlc_project3 --table-name bronze_yellow_taxi --region eu-west-2` lists `["2024","01"]`.
4. Athena (in the project workgroup): `SELECT count(*) FROM nyc_tlc_project3.bronze_yellow_taxi WHERE year='2024' AND month='01'` → **≈ 2,964,624** (must match Project 1's Bronze count).
5. `SELECT * FROM ... LIMIT 10` returns sane, non-null rows across columns → confirms the Bronze schema types/names are correct.
6. Re-run upload → idempotent: partition already exists (handled), count unchanged.
7. CI still green (no AWS calls): `terraform fmt -check`, `terraform validate`, `ruff` on the Python, `sqlfluff` on the DDL.

---
## Appendix A — Dev IAM user policy

The Lambda/IAM/logs permissions this milestone needs are already merged into the
canonical **`iam/dev-user-policy.json`**. Ensure `project3-dev-policy` matches that
file before `terraform apply` (see `iam/README.md` and ADR-012).
