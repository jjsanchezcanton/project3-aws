# Airflow — orchestrated dbt-athena run (Milestone D)

`nyc_tlc_aws` is the orchestrated counterpart to the event-driven Lambda ingest
(ADR-007): the Lambda reacts to new files landing in S3, this DAG deterministically
drives the Silver/Gold transform on demand. It runs `airflow standalone` on the
host in a dedicated `.venv-airflow` (ADR-018), and orchestrates the existing dbt
project via astronomer-cosmos in LOCAL execution mode against the `.venv-dbt/bin/dbt`
executable — dbt-athena is never installed into `.venv-airflow` (ADR-019). See
`docs/specs/milestone_d_airflow_cosmos.md` for the full spec.

## Prerequisite: AWS credentials

```bash
export AWS_PROFILE=project3
```

Export this in the shell **before** starting `airflow standalone` (same convention
as the dbt CLI in Milestone C). It's what lets the `verify_bronze` task's boto3
calls authenticate — the DAG itself contains no profile name or credentials. dbt's
own tasks authenticate separately via `aws_profile_name: project3` already set in
`~/.dbt/profiles.yml`.

## Start standalone

```bash
cd ~/project3-aws
export AWS_PROFILE=project3
source .venv-airflow/bin/activate
export AIRFLOW_HOME=~/project3-aws/airflow
export AIRFLOW__CORE__LOAD_EXAMPLES=False
airflow standalone
```

UI at `http://localhost:8080`. The admin password is printed to stdout and written
to `airflow/standalone_admin_password.txt` (git-ignored).

## Trigger

In the UI: enable and trigger `nyc_tlc_aws`. Or, from a second terminal with the
same venv/env activated:

```bash
airflow dags trigger nyc_tlc_aws
```

## What to expect

Cosmos renders the dbt project as individual tasks — seeds, staging, marts
(including the Iceberg `fct_trips` merge), each followed by its tests. The
`assert_total_amount_reconciliation` test completes **success with a warning**,
not a failure (WARN severity, ADR-016) — a warned task does not fail the DAG.

## Idempotency

Re-triggering is safe: `fct_trips` merges ~0 new rows on a repeat run against the
same Bronze data.
