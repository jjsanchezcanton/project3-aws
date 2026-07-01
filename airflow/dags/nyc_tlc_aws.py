"""
nyc_tlc_aws — orchestrated counterpart to the event-driven Lambda ingest (ADR-007).

Flow: verify_bronze >> dbt_transform (Cosmos renders seeds, staging, marts and
tests as individual Airflow tasks, in dependency order).

dbt runs in Cosmos LOCAL execution mode via the existing .venv-dbt/bin/dbt
(ADR-019) — dbt-athena is never installed into .venv-airflow. Athena creds come
from ~/.dbt/profiles.yml (aws_profile_name: project3); the verify_bronze task
authenticates via whatever AWS_PROFILE is exported in the shell that started
`airflow standalone` (see airflow/README.md) — no credential handling here.
"""
import os
from datetime import datetime

import boto3
from airflow.sdk import DAG
from airflow.providers.standard.operators.python import PythonOperator

from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig
from cosmos.constants import ExecutionMode, LoadMode, TestBehavior

HOME = os.path.expanduser("~")
REPO = f"{HOME}/project3-aws"
DBT_PROJECT_DIR = f"{REPO}/dbt"
DBT_EXECUTABLE = f"{REPO}/.venv-dbt/bin/dbt"
PROFILES_YML = f"{HOME}/.dbt/profiles.yml"

AWS_REGION = "eu-west-2"
GLUE_DATABASE = "nyc_tlc_project3"
GLUE_TABLE = "bronze_yellow_taxi"

profile_config = ProfileConfig(
    profile_name="project3_aws",
    target_name="dev",
    profiles_yml_filepath=PROFILES_YML,
)

execution_config = ExecutionConfig(
    execution_mode=ExecutionMode.LOCAL,
    dbt_executable_path=DBT_EXECUTABLE,
)

render_config = RenderConfig(
    load_method=LoadMode.DBT_LS,
    test_behavior=TestBehavior.AFTER_EACH,
)


def _verify_bronze_partition(**context):
    glue = boto3.client("glue", region_name=AWS_REGION)
    partitions = glue.get_partitions(DatabaseName=GLUE_DATABASE, TableName=GLUE_TABLE)["Partitions"]
    assert partitions, f"No partitions registered on {GLUE_DATABASE}.{GLUE_TABLE} — run ingest first"


with DAG(
    dag_id="nyc_tlc_aws",
    description="NYC TLC pipeline: Bronze pre-check + dbt-athena Silver/Gold transform",
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False,
    tags=["project3", "aws", "dbt", "cosmos"],
) as dag:

    verify_bronze = PythonOperator(
        task_id="verify_bronze",
        python_callable=_verify_bronze_partition,
    )

    transform = DbtTaskGroup(
        group_id="dbt_transform",
        project_config=ProjectConfig(dbt_project_path=DBT_PROJECT_DIR),
        profile_config=profile_config,
        execution_config=execution_config,
        render_config=render_config,
    )

    verify_bronze >> transform
