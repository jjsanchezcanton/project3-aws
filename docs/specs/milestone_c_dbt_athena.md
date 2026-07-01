# Spec — dbt-athena Silver/Gold (Milestone C)

**Component:** `dbt/` — the transformation layer on Athena via dbt-athena.
**Drives:** Milestone C gate — Silver retention ≈95.7%; 3 Gold marts reconcile to the clean fact; `total_amount` discrepancy reproduced as a WARN test.
**Read first:** `CLAUDE.md`, `docs/decisions.md`, and ADRs 013–016 in this spec (append them).
**Reuse:** validity-flag logic from **Project 1** (`silver_yellow_taxi`), dbt structure from **Project 2** (`project2-snowflake-dbt`). This is the "same models, swapped adapter (Snowflake → Athena)" milestone.
**Workflow reminder:** summarise understanding + list ambiguities before writing code. Author reviews line by line.

> ✅ **No IAM change needed for this milestone.** dbt-athena only needs S3 on the project bucket, `glue:*`, and `athena:*` — all already granted by `iam/dev-user-policy.json`. dbt-athena reads credentials from the AWS profile via `aws_profile_name`; no keys go in any dbt file.

## Objective

Build the Silver and Gold layers on Athena with dbt-athena, reading the Bronze Glue table (from Milestone B) as a dbt **source**. Reproduce Project 1's numbers and Project 2's modelling, demonstrating that the same analytics-engineering models port across warehouses by changing the adapter — with one genuine adapter difference made explicit: **Iceberg tables to get `merge` incremental parity with the Snowflake version**.

## Reuse map

- **Silver logic** = Project 1's 6 validity flags (same predicates → same ~95.7% retention). Port them exactly; do not invent new thresholds.
- **dbt structure** = Project 2's staging → intermediate → marts, `trip_key` surrogate, incremental fact, `total_amount` reconciliation test.
- **Seeds** = reuse `taxi_zones` (and optionally `vendor`, `payment_type`, `rate_code`) from Project 2.

## Constraints (Athena / dbt-athena specifics)

- **Stable versions only:** `dbt-athena~=1.10` (pulls a compatible `dbt-core`). Do **not** install `dbt-athena-community` or `dbt-athena-adapter` alongside it (conflicts). Avoid the 1.11 betas.
- **Everything lowercase** — Athena requires lowercase database/schema/table/column names.
- **Workgroup**: dbt runs through `jjs-project-3-de-portfolio-wg`, so the 1 GB bytes-scanned cap applies to dbt queries too (cost guardrail flows through dbt — good talking point).
- **Iceberg**: only the incremental fact uses `table_type='iceberg'` (needs engine v3 ✓ + a unique table location, which dbt-athena manages via `s3_data_dir`). Aggregate marts stay Hive (full-refresh).

## venv + install (new `.venv-dbt`, mirrors Project 2)

```bash
cd ~/project3-aws
uv venv .venv-dbt --python 3.12
source .venv-dbt/bin/activate
uv pip install "dbt-athena~=1.10"
dbt --version          # confirm dbt-core + athena adapter present
```

## dbt profile — `dbt/profiles.example.yml` (real one lives in `~/.dbt/profiles.yml`)

```yaml
project3_aws:
  target: dev
  outputs:
    dev:
      type: athena
      region_name: eu-west-2
      database: awsdatacatalog                 # the Glue catalog (dbt "database" level)
      schema: nyc_tlc_project3                  # default Glue database (where Bronze lives)
      work_group: jjs-project-3-de-portfolio-wg # enforces the bytes cap on dbt queries
      s3_staging_dir: s3://jjs-project-3-de-portfolio-722448938150/athena-results/
      s3_data_dir:    s3://jjs-project-3-de-portfolio-722448938150/dbt/
      s3_data_naming: schema_table
      aws_profile_name: project3                # uses ~/.aws profile — NO keys in this file
      threads: 4
```

The `profile:` in `dbt_project.yml` must be `project3_aws`. Commit only the `.example`; the real profile is git-ignored / lives in `~/.dbt`.

## dbt_project.yml (key config)

```yaml
name: project3_aws
profile: project3_aws
models:
  project3_aws:
    staging:      { +materialized: view }
    intermediate: { +materialized: ephemeral }
    marts:        { +materialized: table }     # fct overrides to incremental/iceberg per-model
```

Port Project 2's `generate_schema_name` macro so models route to dedicated Glue databases (all lowercase): staging → `nyc_tlc_project3_staging`, marts → `nyc_tlc_project3_marts`. dbt-athena creates these databases automatically (covered by `glue:*`). See ADR-015.

## Sources — `models/staging/_sources.yml`

```yaml
version: 2
sources:
  - name: bronze
    database: awsdatacatalog
    schema: nyc_tlc_project3
    tables:
      - name: bronze_yellow_taxi      # the Glue table from Milestone B; dbt does NOT own it (ADR-014)
```

## Models

### staging (views)
- `stg_yellow_trips`: `select` from `{{ source('bronze','bronze_yellow_taxi') }}`, rename to snake_case, light casts. No filtering yet.
- `stg_taxi_zones`: from the `taxi_zones` seed (locationid, borough, zone).

### intermediate (ephemeral) — this is the **Silver logic**
- `int_trips_clean`:
  - Apply Project 1's **6 validity flags** as boolean columns, then filter to rows passing all six. Use the *exact* predicates from `silver_yellow_taxi` so retention matches. Typical set (confirm against Project 1):
    1. `passenger_count` in valid range (e.g. 1–8)
    2. `trip_distance > 0` (and within an upper bound)
    3. `fare_amount >= 0`
    4. `total_amount >= 0`
    5. `tpep_pickup_datetime < tpep_dropoff_datetime` and duration within bounds
    6. `pulocationid` and `dolocationid` in 1–265
  - Deduplicate (row_number over the natural key, keep first).
  - Derive `trip_duration_min` and `trip_key = {{ dbt_utils.generate_surrogate_key([...]) }}` over the same natural-key columns Project 2 used (vendorid, pickup, dropoff, pu, do, total_amount).

### marts
- **`fct_trips`** — the persisted clean fact (Silver persisted). **The adapter-difference showcase:**
  ```sql
  {{ config(
      materialized='incremental',
      table_type='iceberg',
      incremental_strategy='merge',
      unique_key='trip_key',
      format='parquet'
  ) }}
  ```
  Select cleaned columns + measures from `int_trips_clean`; on incremental runs, filter to `pickup_at > (select max(pickup_at) from {{ this }})` (watermark guard). First run = full build; re-run with no new data merges ~0 rows.
- **`agg_daily_kpis`** (Hive `table`): per day — trips, total revenue, avg fare, % paid by card. (Project 1 mart 1)
- **`agg_pickup_zone`** (Hive `table`): per pickup zone (joined to `stg_taxi_zones` for borough/zone names) — trips, revenue. (Project 1 mart 2)
- **`agg_hour_of_day`** (Hive `table`): trips by hour-of-day × day-of-week. (Project 1 mart 3)

*Optional stretch (parity with Project 2, not required for the gate):* a few `dim_*` to complete the star, and the `snap_rate_policy` SCD2 snapshot (Iceberg). Park unless time allows.

## Tests — `models/marts/_marts.yml` + `tests/`

- Generic: `not_null` + `unique` on `fct_trips.trip_key`; `relationships` from `fct_trips.pulocationid` to `stg_taxi_zones.locationid`; `accepted_values` on `payment_type`.
- **Singular `assert_total_amount_reconciliation`** (WARN severity): checks `total_amount` vs the sum of its components within a tolerance; configured `severity: warn` so it surfaces the discrepancy rate without failing the build. Port from Project 2 (the ~21.3% finding). See ADR-016.
- **Reconciliation singular tests**: `sum(trips)` in each of the 3 aggregate marts equals `count(*)` of `fct_trips`.

## Decisions (append to `docs/decisions.md`)

**ADR-013 — Iceberg for the incremental fact, Hive for the aggregate marts.** *Why:* Project 2's `fct_trips` used Snowflake's native `merge`; Athena-Hive has no merge (only `insert_overwrite`/`append`), so to keep true merge parity the fact is an **Iceberg** table (`incremental_strategy='merge'`). The aggregate marts are full-refresh, so plain Hive `table` is simpler and cheaper. *Interview line:* "Same dbt model as the Snowflake version; on Athena I reached for Iceberg specifically to preserve merge semantics — Hive would have forced insert_overwrite." *When Hive insert_overwrite would win:* large append-only/partition-replace facts where merge isn't needed and you want to avoid Iceberg's metadata overhead.

**ADR-014 — Bronze is a dbt source, not a dbt model.** *Why:* Bronze is owned by Terraform + the ingest Lambda (Milestone B); dbt reads it via `source()` and starts at staging. Keeps the ingest/transform boundary clean and lets the event-driven layer evolve independently. *When dbt would own ingest too:* a dbt-only shop using `dbt seed`/external tables for raw, with no separate ingestion service.

**ADR-015 — Schema routing to per-layer Glue databases.** *Why:* a `generate_schema_name` override lands staging/marts in their own lowercase Glue databases (`nyc_tlc_project3_staging` / `_marts`) instead of dbt's default target-prefixed names — clean separation, mirrors Project 2. *When a single database would win:* very small projects where one database with model-name prefixes is simpler than managing several.

**ADR-016 — `total_amount` reconciliation as WARN, not error.** *Why:* ~21% of TLC trips don't reconcile due to how the congestion surcharge is reflected upstream — a source-data issue that cannot be fixed downstream. Failing the build on it would be wrong; monitoring it is right, so the test is WARN severity. Identical call to Project 2 → cross-project consistency. *When ERROR would win:* a reconciliation invariant the pipeline itself is responsible for (e.g., a join that must not drop rows).

## Acceptance asserts

From `.venv-dbt`, with `AWS_PROFILE=project3`:
1. `dbt deps` then `dbt seed` then `dbt build` (run + test) complete successfully.
2. `fct_trips` row count ≈ **95.7% of Bronze** (≈ 2.84M of 2,964,624) — must match Project 1's Silver retention.
3. The 3 aggregate marts each reconcile to `fct_trips` row count (reconciliation tests pass).
4. `assert_total_amount_reconciliation` runs at **WARN**, reporting the non-reconciling rate (~21%); build does **not** fail.
5. Re-run `dbt build`: `fct_trips` (Iceberg merge) processes ~0 new rows / is idempotent; aggregates rebuild identically.
6. In Athena (project workgroup): `SELECT * FROM nyc_tlc_project3_marts.agg_daily_kpis ORDER BY trip_date LIMIT 5` returns sane KPIs.
7. (No-AWS, for Milestone E CI) `dbt parse` succeeds with dummy creds.

## How to run

```bash
cd ~/project3-aws && source .venv-dbt/bin/activate
export AWS_PROFILE=project3
cp dbt/profiles.example.yml ~/.dbt/profiles.yml   # then edit bucket/account if needed
cd dbt
dbt deps
dbt seed
dbt build                 # staging (views) → marts + tests; fct_trips is Iceberg/merge
# then run the Athena asserts above
```

---

## Appendix — dbt-athena gotchas to watch in review

- **Iceberg unique location:** if `fct_trips` errors on rebuild, it's usually the table location / backup-table handling — Iceberg needs a unique location, which `s3_data_dir` + `s3_data_naming: schema_table` provides. Don't point two models at the same location.
- **Lowercase everywhere** — a capitalised schema/table name will fail on Athena.
- **First Iceberg run is a full build**; the watermark/merge only kicks in from the second run. Don't expect incremental behaviour on run #1.
- **Seeds**: `taxi_zones.csv` must be reused/committed under `dbt/seeds/`; the by-zone mart depends on it.
