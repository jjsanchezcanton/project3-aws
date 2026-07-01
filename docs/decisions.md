# Architecture Decision Records — Project 3 (AWS + dbt-athena)

Format: each ADR states context, the decision, consequences, and — for exclusion decisions — the conditions under which the rejected option *would* be the correct call. The exclusion ADRs are written deliberately as senior-interview talking points.

---

## ADR-001 — AWS region: eu-west-2 (London)

**Status:** Accepted

**Context.** All AWS resources must live in a single region. The portfolio presents as UK-based, the data is a fixed public dataset, and there is no latency-sensitive consumer.

**Decision.** Use **eu-west-2 (London)** for every resource.

**Consequences.** Region alignment with the UK positioning; all services in scope (S3, Lambda, Glue, Athena) are available in eu-west-2. Athena query results, the Glue catalog, and the S3 buckets are all pinned to the same region to avoid cross-region data-transfer charges. The region is a single Terraform variable, so the project is trivially re-homable.

**When another region would be right.** If a real consumer or data source were in another region, co-locating with it would cut transfer cost and latency. For a fixed public dataset with no live consumer, region choice is a positioning/consistency decision, not a technical one.

---

## ADR-002 — Serverless, free-tier-only architecture

**Status:** Accepted

**Context.** Unlike the GCP and Snowflake trials used in Projects 1 and 2, AWS has no blanket trial; some services (Redshift, MWAA, Glue Spark) bill continuously. The project must cost effectively nothing and never surprise-bill.

**Decision.** Build a **fully serverless, pay-per-use** lakehouse: S3 + Lambda + Glue Data Catalog + Athena, orchestrated by local Airflow in Docker, provisioned by Terraform. Enforce cost guardrails *as code*:
- An **AWS Budget** with an alarm at a low threshold (e.g. $1 / $5).
- An **Athena workgroup with a per-query bytes-scanned cap**, so a runaway query fails instead of billing.
- **Parquet + partitioning** everywhere, so Athena scans only the columns/partitions a query needs.
- `terraform destroy` discipline; the only standing cost is a few MB of S3 storage (fractions of a cent/month).

**Consequences.** When idle, the stack bills ~$0 — the opposite of capacity-based services. This *is* the cost-aware narrative for interviews: "the design's standing cost is zero because nothing is provisioned to sit running." Credentials are never committed (`.env` + `.gitignore`); IAM is least-privilege (detailed ADR at Milestone B).

**When this would be wrong.** At sustained, high-concurrency, low-latency BI scale, pay-per-use becomes more expensive than amortised provisioned capacity — see ADR-003 and ADR-006.

---

## ADR-003 — Athena as the warehouse; exclude Redshift

**Status:** Accepted

**Context.** The warehouse/serving layer could be Redshift (provisioned or Serverless) or Athena over S3.

**Decision.** Use **Amazon Athena (engine v3)** as the query/serving layer. **Exclude Redshift.**

**Rationale.** Athena bills **$5/TB scanned with a 10 MB per-query minimum; DDL and failed queries are free**. At this volume (one month, ~50 MB Parquet, columnar + partitioned) every query scans a tiny fraction of a TB, so the whole project costs pennies. Redshift bills by **capacity over time** — Redshift Serverless from ~$1.50/RPU-hour (scales to zero when idle), Provisioned from ~$0.54/hour — with no clean perpetual free tier. For a bursty, low-volume, single-developer workload, Athena is both cheaper and simpler, and needs no cluster to manage.

**Consequences.** No always-on warehouse; serving is ad-hoc Athena SQL. Note for interviews: never call Athena "free" — say "pay-per-scan, negligible at this scale, with a workgroup byte cap as a guardrail."

**When Redshift would be right.** Sustained, high-concurrency BI (dashboards hit all day by many users), sub-second latency SLAs, or workloads running 8+ hours/day against the same optimised dataset — there the fixed capacity cost amortises across many queries and beats $5/TB. Redshift also wins for heavy joins on pre-loaded, distribution-key-tuned data. At that point the per-query model loses.

---

## ADR-004 — dbt-athena for transformations (over hand-written CTAS)

**Status:** Accepted

**Context.** Silver/Gold transformations on Athena can be hand-written `CREATE TABLE AS SELECT` SQL orchestrated by Airflow, or expressed as dbt models via the dbt-athena adapter. Note that the adapter is not a different engine — **dbt-athena generates the same CTAS / CREATE VIEW statements in Athena under the hood**; the choice is whether to add dbt's modelling, testing, docs, and incremental framework on top.

**Decision.** Use **dbt-core + dbt-athena** for Silver and Gold. Keep the **Bronze external table in native Athena DDL** (it is AWS-catalog plumbing, not a transformation). dbt-athena is officially maintained by dbt Labs and supported in dbt Cloud, so this is a production-grade, current pattern (dbt-core 1.11.x / dbt-athena 1.10.x).

**Rationale.**
- **Market signal.** dbt is the dominant transformation framework in modern data engineering and appears explicitly in the target JDs (IC Resources, YLD). More dbt surface area across the portfolio raises credibility and keyword density.
- **Senior talking point.** Reusing the *same dbt models from Project 2* on a different adapter demonstrates warehouse portability and understanding of the adapter pattern: "same models, swapped Snowflake for Athena — here's what changed (incremental strategy, table format, type handling) and what didn't (the model DAG, the tests, the lineage)."
- **Free outputs.** dbt tests reproduce the `total_amount` reconciliation finding as a WARN; `dbt docs` republishes a lineage site to GitHub Pages — the same recruiter-visible artifact that worked in Project 2.
- **Speed.** Reuses Project 2 model logic, keeping Project 3 the smallest of the four.

**Consequences.** Adds dbt-core + dbt-athena to the stack. The genuinely AWS-specific learning (S3 lakehouse, Glue catalog, Lambda event ingest, Athena engine, IAM, Terraform AWS, the amazon/Cosmos orchestration) is unchanged by this choice, so no AWS depth is lost. To avoid Project 3 reading as "Project 2 with a new warehouse," the README foregrounds the native AWS ingest/catalog layer and the adapter-swap comparison.

**When native CTAS would be right.** A tiny one-off transform, a shop with no dbt footprint, or a context where adding a dbt dependency isn't justified — there hand-written CTAS orchestrated directly by Airflow is leaner. We document a couple of native-DDL steps (Bronze table) precisely so both stories can be told.

---

## ADR-005 — Local Airflow 3.2 in Docker; exclude MWAA

**Status:** Accepted

**Context.** Orchestration could run on MWAA (Amazon Managed Workflows for Apache Airflow) or local Airflow in Docker hitting real AWS.

**Decision.** Run **Apache Airflow 3.2.x locally in Docker**, orchestrating dbt via **astronomer-cosmos** (the Project 2 pattern), authenticated to AWS through the dev IAM profile. **Exclude MWAA.**

**Rationale.** MWAA bills for an always-on environment (roughly $350+/month if left running) — incompatible with the free-tier constraint and unnecessary for a single-developer portfolio. Local Airflow is free, reproducible from `docker compose`, and reuses the Project 1 (local Airflow) and Project 2 (Cosmos) patterns, so it also ties the portfolio together.

**Consequences.** Airflow runs on the laptop, not in AWS; the DAG reaches AWS via boto3/providers using local credentials. No managed HA/scaling — irrelevant at this scale.

**When MWAA would be right.** A team needing managed HA, IAM-integrated execution roles, VPC-private operators, and no ops burden for a production schedule — there MWAA's cost buys real operational value. For a portfolio it buys nothing.

---

## ADR-006 — Exclude Glue Spark ETL jobs; transforms via dbt-athena

**Status:** Accepted

**Context.** Transformations could run on AWS Glue (managed Spark, billed per DPU-hour) or as Athena SQL via dbt-athena.

**Decision.** Do transformations with **dbt-athena (Athena SQL/CTAS)**. **Exclude Glue Spark ETL jobs.**

**Rationale.** Glue Spark bills per DPU-hour (minimum DPUs, per-second billing) — real money for repeated dev runs. At this data volume, Athena SQL expresses the same medallion logic for pennies and needs no Spark cluster. The Glue *Data Catalog* is still used (it is free at this scale) — only Glue *Spark ETL jobs* are excluded.

**Consequences.** Transform logic is SQL, not PySpark. Project 1 already demonstrates PySpark on Databricks, so no Spark skill is hidden by this choice.

**When Glue/EMR Spark would be right.** Very large datasets, complex non-SQL transformations (custom UDFs, ML feature pipelines, multi-stage Spark), or when reading the lake at a scale where $5/TB Athena scans exceed amortised Spark compute. There managed/elastic Spark beats per-query SQL.

---

*ADRs 001–006 written at Milestone A. Further ADRs (event-driven ingest, crawler-vs-DDL, IAM least-privilege, schema-on-read, idempotency) are written at Milestones B and C as those decisions are implemented.*

---

## ADR-007 — Event-driven ingest (Lambda + S3 events).

Ingest is triggered by the S3 `ObjectCreated` event on `landing/`, not a schedule or a poll. *Why:* reactive, decoupled, demonstrates the canonical AWS serverless ingest pattern; the orchestrated path (Airflow, Milestone D) drives the *deterministic* transform sequence — two complementary patterns. *When polling/scheduled would win:* sources that don't emit events, or strict batch windows where you want a single controlled trigger time.

---

## ADR-008 — Partition registration via Glue API in the Lambda, not a crawler, not partition projection.

*Why:* a crawler costs DPU-hours and is non-deterministic; partition projection is free but removes the event-driven registration that is the *point* of this milestone. Explicit `CreatePartition` is deterministic and free. *When projection would win:* large, regular, predictable partition layouts where you never want per-file logic — then projection beats both.

---

## ADR-009 — Bronze external table defined in Terraform (`aws_glue_catalog_table`), schema declared (not VARIANT).

*Why:* IaC source of truth, reproducible with the rest of the stack, removed by `terraform destroy`; Athena over parquet has no VARIANT, so the schema is declared, with a verification step against the real file to absorb TLC drift. A readable SQL mirror is committed as documentation. *When Athena DDL alone would win:* throwaway exploration where IaC overhead isn't justified.

---

## ADR-010 — Least-privilege Lambda execution role + scoped `PassRole`.

*Why:* the execution role can only read `landing/`, write `bronze/`, and manage partitions on the one table; the dev user's `iam:PassRole` is conditioned to `lambda.amazonaws.com` and role/policy management is ARN-scoped to `jjs-project-3-*`. *Interview point:* "I scoped PassRole with a service condition rather than granting `iam:PassRole` on `*`."

---

## ADR-011 — Lambda is dependency-light (boto3 only); no parquet parsing.

*Why:* validates by key pattern + object size, not content — avoids a heavy pyarrow layer, keeps cold starts and packaging trivial, stays free. Row-level validation belongs in the Silver dbt layer (Milestone C), not at ingest. *When content validation at ingest would win:* when malformed files must be rejected before landing and a schema/row check is cheap relative to downstream cost.

---

## ADR-012 — Dev IAM user policy is documentation-managed, not Terraform-managed

**Status:** Accepted

**Context.** Terraform authenticates to AWS as the dev user `jjs-project3-dev`.
Managing that user's own policy from the same Terraform state is a bootstrap /
circular dependency — the identity provisioning the stack would be mutating its
own permissions — and long-lived human-credential permissions are better kept
auditable and out of state.

**Decision.** The dev user and its policy are created and maintained by hand. The
canonical policy lives at `iam/dev-user-policy.json` (single source of truth) and
is applied manually via the IAM console or `aws iam create-policy-version`. Spec
appendices reference this file instead of restating the policy. Terraform manages
only resource-side roles, such as the Lambda execution role.

**Consequences.** Permission changes are one paste of the whole file, with no
drift across specs. Scoping: S3 to the project bucket; IAM/Lambda to the
`jjs-project-3-*` name pattern; `iam:PassRole` conditioned to `lambda.amazonaws.com`;
Glue/Athena/Budgets service-wide (resource-level scoping awkward) — acceptable in a
solo account, tightened in a shared one.

**When Terraform-managing it would be right.** A separate bootstrap/admin principal
(or IAM Identity Center) provisions the dev user, so the stack's own identity is not
mutating itself — then the policy can live in IaC too.

---

*ADRs 007–012 written at Milestone B. Further ADRs (event-driven ingest, crawler-vs-DDL, IAM least-privilege, schema-on-read, idempotency) are written at Milestone C as those decisions are implemented.*

---

## ADR-013 — Iceberg for the incremental fact, Hive for the aggregate marts.

*Why:* Project 2's `fct_trips` used Snowflake's native `merge`; Athena-Hive has no merge (only `insert_overwrite`/`append`), so to keep true merge parity the fact is an **Iceberg** table (`incremental_strategy='merge'`). The aggregate marts are full-refresh, so plain Hive `table` is simpler and cheaper. *Interview line:* "Same dbt model as the Snowflake version; on Athena I reached for Iceberg specifically to preserve merge semantics — Hive would have forced insert_overwrite." *When Hive insert_overwrite would win:* large append-only/partition-replace facts where merge isn't needed and you want to avoid Iceberg's metadata overhead.

---

## ADR-014 — Bronze is a dbt source, not a dbt model.

*Why:* Bronze is owned by Terraform + the ingest Lambda (Milestone B); dbt reads it via `source()` and starts at staging. Keeps the ingest/transform boundary clean and lets the event-driven layer evolve independently. *When dbt would own ingest too:* a dbt-only shop using `dbt seed`/external tables for raw, with no separate ingestion service.

---

## ADR-015 — Schema routing to per-layer Glue databases.

*Why:* a `generate_schema_name` override lands staging/marts in their own lowercase Glue databases (`nyc_tlc_project3_staging` / `_marts`) instead of dbt's default target-prefixed names — clean separation, mirrors Project 2. *When a single database would win:* very small projects where one database with model-name prefixes is simpler than managing several.

---

## ADR-016 — `total_amount` reconciliation as WARN, not error.

*Why:* ~21% of TLC trips don't reconcile due to how the congestion surcharge is reflected upstream — a source-data issue that cannot be fixed downstream. Failing the build on it would be wrong; monitoring it is right, so the test is WARN severity. Identical call to Project 2 → cross-project consistency. *When ERROR would win:* a reconciliation invariant the pipeline itself is responsible for (e.g., a join that must not drop rows).

## ADR-017 — Multi-month readiness: partition-relative cleaning + independent date dimension

**Status:** Accepted

**Context.** The initial Silver filter excluded out-of-period trips with a hardcoded
January 2024 timestamp range, and `dim_date` was derived only from the dates present
in the data. Both assumptions break the moment a second month is processed: a
hardcoded month would filter every other month to zero rows, and a data-derived
`dim_date` would fail the `fct_trips → dim_date` relationship test for any date it
had never seen.

**Decision.**
1. `int_trips_clean` validates each trip against **its own ingest partition**
   (`year(pickup_at) = partition_year and month(pickup_at) = partition_month`),
   not against a fixed month. The partition keys travel from Bronze (registered by
   the ingest Lambda) through staging.
2. `dim_date` is a fixed, independent calendar built with `dbt_utils.date_spine`
   over a wide range (2023–2026), decoupled from whatever data is loaded.

**Consequences.** The pipeline processes any month with no code change: each month's
out-of-period rows are dropped relative to that month, and the relationship test holds
because the calendar already covers every plausible date. January's result is
unchanged (still ~95.71% retention; the same ~17 out-of-period rows removed).

**When the simpler version would be right.** A genuinely single-shot, single-month
backfill that will never be re-run — there a hardcoded range and a data-derived date
dimension are acceptable shortcuts. For an incremental pipeline they are technical debt.

---

*ADRs 013–017 written at Milestone C. Further ADRs might be written at Milestone D as those decisions are implemented.*