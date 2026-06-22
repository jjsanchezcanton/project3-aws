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
