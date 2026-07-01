# Spec — Airflow 3.2 + Cosmos orchestration (Milestone D)

**Component:** `airflow/` — local Apache Airflow 3.2 (standalone venv) orchestrating the dbt-athena project via astronomer-cosmos.
**Drives:** Milestone D gate — DAG `nyc_tlc_aws` runs green end-to-end on manual trigger, idempotent, with the dbt project rendered as individual Cosmos tasks.
**Read first:** `CLAUDE.md`, `docs/decisions.md`, ADRs 018–019 in this spec.
**Reuse:** the Cosmos DAG shape from **Project 2** (`~/reference/project2-snowflake-dbt/airflow/`) — same `ProjectConfig` / `ProfileConfig` / `ExecutionConfig` / `RenderConfig` pattern, adapted for the athena profile.
**Workflow reminder:** summarise understanding + list ambiguities before writing code. Author reviews line by line.

> ✅ **No IAM change, and no credential plumbing.** Airflow runs on the host, so dbt-athena authenticates through the same `~/.aws` profile (`project3`) the CLI already uses. Nothing new to configure for auth.

## Objective

Orchestrate the Silver/Gold transformation (the Milestone C dbt project) as an Airflow 3.2 DAG using Cosmos in **LOCAL execution mode**, rendering each seed / model / test as an individual Airflow task. Manual-trigger, idempotent. This is the orchestrated counterpart to the event-driven ingest (ADR-007) — the two patterns are complementary.

## Approach (why standalone venv, not Docker)

See ADR-018. In short: `airflow standalone` in a dedicated venv lets dbt-athena reuse the host `~/.aws` `project3` profile directly, eliminating the container-credential problem entirely, and mirrors Project 2. Cosmos runs dbt in LOCAL mode via `dbt_executable_path` pointing at the existing `.venv-dbt` dbt binary — one dbt install, reused.

## Environment setup (`.venv-airflow`, mirrors Project 2)

```bash
cd ~/project3-aws
uv venv .venv-airflow --python 3.12
source .venv-airflow/bin/activate
uv pip install "apache-airflow==3.2.1" \
  --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-3.2.1/constraints-3.12.txt"
uv pip install "astronomer-cosmos>=1.14"     # 1.14+ supports Airflow 3.2
deactivate
```

- `.venv-airflow` holds **only** Airflow + Cosmos. dbt-athena stays in `.venv-dbt`; Cosmos invokes it via `dbt_executable_path` (LOCAL mode). See ADR-019.
- `AIRFLOW_HOME = ~/project3-aws/airflow`; DAGs in `airflow/dags/`.

## Files

```
airflow/
├── dags/
│   └── nyc_tlc_aws.py         # the Cosmos DAG
├── .gitignore                 # ignore airflow.db, logs/, standalone_admin_password.txt, etc.
└── README.md                  # how to start standalone + trigger
.env.example                   # add AIRFLOW_HOME line (documentation)
```

Add to the repo-root `.gitignore` (Airflow runtime artefacts must never be committed):
```
airflow/airflow.db
airflow/logs/
airflow/*.cfg
airflow/*.pid
airflow/standalone_admin_password.txt
airflow/simple_auth_manager_passwords.json.generated
```

## DAG spec — `airflow/dags/nyc_tlc_aws.py`

Cosmos configuration objects (adapt Project 2's DAG):

- **`ProjectConfig`**: `dbt_project_path = "/home/juanjose/project3-aws/dbt"` (absolute), `seeds_relative_path`/`models` default.
- **`ProfileConfig`**:
  - `profile_name="project3_aws"`, `target_name="dev"`.
  - `profiles_yml_filepath="/home/juanjose/.dbt/profiles.yml"` — reuses the working profile (with `aws_profile_name: project3`). No Cosmos profile-mapping needed; the host `~/.aws` resolves creds.
- **`ExecutionConfig`**: `execution_mode=ExecutionMode.LOCAL`, `dbt_executable_path="/home/juanjose/project3-aws/.venv-dbt/bin/dbt"`.
- **`RenderConfig`**: `load_method=LoadMode.DBT_LS` (runs `dbt ls` at parse — metadata only, no warehouse connection, so safe and credential-light), `test_behavior=TestBehavior.AFTER_EACH` (model then its tests → the granular graph).

DAG shape:
```python
with DAG("nyc_tlc_aws", schedule=None, catchup=False, ...) as dag:
    verify_bronze = PythonOperator(...)      # optional pre-check (see below)
    transform = DbtTaskGroup(
        group_id="dbt_transform",
        project_config=..., profile_config=..., execution_config=..., render_config=...,
    )
    verify_bronze >> transform
```

- **`schedule=None`** → manual trigger only (matches Project 1's on-demand pattern; a taxi-analytics backfill isn't a cron job).
- **Optional `verify_bronze`** (PythonOperator, boto3): asserts the Bronze partition exists via `glue.get_partitions(...)` before transforming — a nice "orchestrated pipeline validates its input" touch. Keep it lightweight; if it adds friction, ship the DbtTaskGroup alone and add this later.
- The `DbtTaskGroup` renders seeds → staging (views) → marts (incl. the Iceberg `fct_trips`) → tests as individual tasks, exactly like the Project 2 graph.

## Decisions (append to `docs/decisions.md`)

**ADR-018 — Local Airflow via standalone venv, superseding the Docker note in ADR-005.**
*Status:* Accepted (supersedes the Docker detail of ADR-005; the "exclude MWAA" decision in ADR-005 stands unchanged).
*Context.* ADR-005 specified local Airflow "in Docker". In practice, getting AWS credentials into an Airflow container reliably (uid alignment, mounting `~/.aws`, or injecting keys) is the most failure-prone part of a local Docker setup.
*Decision.* Run Airflow 3.2 with `airflow standalone` in a dedicated `.venv-airflow`, on the host. dbt-athena then authenticates through the host `~/.aws` `project3` profile with zero extra credential plumbing, and this mirrors the proven Project 2 setup.
*Consequences.* Simpler, fewer moving parts, no container credential handling; Airflow runtime files stay on the host (git-ignored). *When Docker would win:* a shared/production deployment needing image reproducibility and isolation — there the container-credential work is justified (and you'd use an IAM role, not static keys).

**ADR-019 — Cosmos LOCAL execution mode reusing the `.venv-dbt` dbt executable.**
*Context.* Cosmos can run dbt in LOCAL, VIRTUALENV, or container modes.
*Decision.* LOCAL mode with `dbt_executable_path` pointing at the existing `.venv-dbt/bin/dbt`. One dbt-athena install, reused by both the CLI and the orchestrator; `RenderConfig` uses `DBT_LS` (metadata-only parse, no warehouse hit at DAG-parse time).
*Consequences.* No duplicate dbt install, no per-task virtualenv rebuild; identical adapter/version in CLI and orchestration. Same pattern as Project 2. *When VIRTUALENV/Docker modes would win:* isolating conflicting dbt/adapter versions per project, or running dbt in a separate runtime from Airflow.

## Acceptance asserts

1. `.venv-airflow` created; `astronomer-cosmos>=1.14` and `apache-airflow==3.2.1` installed.
2. `airflow standalone` starts; UI reachable at `http://localhost:8080` (admin password printed / in `airflow/standalone_admin_password.txt`).
3. DAG `nyc_tlc_aws` appears and **parses with no import errors**.
4. In the Graph view, Cosmos has rendered the dbt project as **individual tasks** (seeds, staging, marts, tests) — the granular graph, as in Project 2.
5. Manual trigger → the DAG runs **green end-to-end**; models and tests execute via Cosmos against Athena.
6. The `assert_total_amount_reconciliation` test task completes as **success with a warning** (WARN severity does not fail the task / the DAG).
7. **Idempotency:** a second manual trigger runs green; `fct_trips` merges ~0 new rows.

## How to run

```bash
# 1. start Airflow standalone
cd ~/project3-aws
source .venv-airflow/bin/activate
export AIRFLOW_HOME=~/project3-aws/airflow
airflow standalone
# note the admin password it prints; UI at http://localhost:8080

# 2. in the UI: enable + trigger the DAG 'nyc_tlc_aws' (or:)
#    airflow dags trigger nyc_tlc_aws
```

The dbt profile's `work_group: jjs-project-3-de-portfolio-wg` still applies, so orchestrated queries also respect the 1 GB bytes-scanned cap.

---

## Appendix — gotchas to watch in review

- **Absolute paths** in `ProjectConfig`/`ProfileConfig`/`ExecutionConfig` — Cosmos does not expand `~`; use `/home/juanjose/...` (or `os.path.expanduser`).
- **Airflow 3.2 `schedule=`** (not the deprecated `schedule_interval`); `catchup=False`.
- **`DBT_LS` at parse** needs the dbt executable resolvable at the given path and `dbt deps` already run in `dbt/` (the `dbt_packages/` must exist) — run `dbt deps` in `.venv-dbt` first if not present.
- **WARN mapping:** confirm the reconciliation test task is green-with-warning, not failed. If Cosmos is configured to treat dbt warnings as failures, relax that so warn-severity behaves like the CLI.
- Don't commit `airflow/airflow.db`, `logs/`, or the standalone password file (in `.gitignore`).
