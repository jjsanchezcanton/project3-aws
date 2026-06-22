# CLAUDE.md — Project 3 (AWS + dbt-athena)

Guidance for Claude Code working in this repository. Read this file, the relevant ADR(s) in `docs/decisions.md`, and the task spec in `docs/specs/` **before writing any code**. Summarise your understanding and surface ambiguities first; only then write. The author reviews every generated file line by line before it runs.

## What this project is

The third of four portfolio implementations of one NYC TLC Yellow Taxi pipeline (ingest → clean → model → serve), built on **AWS** with **dbt-athena**. Sibling repos: `project1-gcp-databricks`, `project2-snowflake-dbt`. The goal is credible senior AWS hands-on plus a cost-aware, serverless design story. This is the *smallest* of the four — reuse Project 2's dbt model logic; don't expand scope.

## Spec-driven workflow (non-negotiable)

1. Decision recorded in `docs/decisions.md` (ADR) first.
2. A spec written in `docs/specs/` for any non-trivial component.
3. Claude Code reads CLAUDE.md + the ADR + the spec, **summarises its understanding and lists ambiguities before coding**.
4. Author resolves ambiguities.
5. Author reviews the generated file line by line.
6. The file runs in its target environment and **acceptance asserts** are checked.

## Hard constraints

- **Free-tier / pay-per-use only.** No Redshift, no MWAA, no Glue Spark ETL jobs (see ADR-003/005/006). Glue *Data Catalog* is fine.
- **Region: eu-west-2 (London)**, as a single Terraform variable (ADR-001).
- **Cost guardrails as code** (ADR-002): AWS Budget alarm; Athena workgroup with a per-query bytes-scanned cap; Parquet + partitioning on every table; `terraform destroy` leaves no orphans.
- **Latest stable versions:** Airflow 3.2.x · Terraform 1.15.x with `hashicorp/aws ~> 6.0` · dbt-core 1.11.x + dbt-athena 1.10.x · Python 3.12 (via uv) · `apache-airflow-providers-amazon` resolved through the Airflow 3.2 constraints file. Pin versions; prefer newest stable over older.
- **Security:** never write credentials into the repo or into code. Credentials come from `~/.aws` (AWS CLI profile) and environment variables only. `.env` is git-ignored; only `.env.example` and `terraform.tfvars.example` are committed. IAM is least-privilege (dev user + a scoped Lambda execution role).
- **No crawler.** Register the Bronze partition via Glue API / native DDL, not a Glue crawler (cost/determinism). dbt-athena manages Silver/Gold tables.

## Cross-project consistency (must reproduce)

- Same partition as Project 1: **Yellow Taxi, Jan 2024 (~2.96M rows)**.
- Silver applies the **same 6 validity flags** as Project 1; retention should land near **95.7%**.
- The **3 Gold marts** (daily KPIs, by pickup zone, by hour-of-day) must reconcile exactly to the Silver row count (dbt tests).
- Reproduce the **`total_amount` reconciliation finding** (~21.3% of trips don't reconcile) as a **WARN-severity dbt test**, not a build failure — same call as Project 2.
- Serving answers the **same 4 stakeholder questions** as the Project 1 dashboard.

## Conventions

- Project/resource naming: `jjs-project-3-de-portfolio` (mirrors Project 1's `jjs-project-1-de-portfolio`). S3 bucket names must be globally unique — derive with a suffix (account id or random) via Terraform, never hardcode.
- S3 layout: `landing/`, `bronze/`, `silver/`, `gold/`, `athena-results/`.
- dbt layout: `models/{staging,intermediate,marts}/`, `seeds/`, `tests/`; explicit schema/`s3` location config; incremental Gold/fact where it makes sense (mirror Project 2's `fct_trips` merge pattern, adapted to dbt-athena's Iceberg/Hive incremental strategies).
- Orchestration: Airflow 3.2 + astronomer-cosmos (LOCAL execution mode), reusing the Project 2 DAG shape.
- Two isolated Python venvs as in Project 2: one for dbt/loader, one for Airflow+Cosmos (`uv venv`).
- Repo structure as defined in the build brief (`Project3_AWS_Brief.md`, §6).

## CI principles

- PR CI must **not** touch AWS: `dbt parse` (dummy/credential-free), `terraform fmt -check` + `terraform validate`, `sqlfluff` (Athena dialect), `ruff`. PRs cost nothing (Project 2 principle).
- A separate `docs.yml` (push to `main`) may publish the dbt docs site to GitHub Pages.

## What "done" means

Match the acceptance criteria in the build brief (§8). Every non-trivial file ships with acceptance asserts that prove it works (row counts, reconciliation, idempotency on re-run, `terraform destroy` cleanliness).
