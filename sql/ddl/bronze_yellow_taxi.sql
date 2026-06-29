-- Documentation only — source of truth is terraform/glue_tables.tf.
-- Schema verified against the real yellow_tripdata_2024-01.parquet file
-- (pyarrow.parquet.read_schema), not just TLC's published data dictionary:
-- vendorid/pulocationid/dolocationid are int32 -> int; passenger_count/ratecodeid/
-- payment_type are int64 -> bigint in this month's file (TLC has stored these as
-- double in other months — re-verify per partition before reuse, ADR-009).
CREATE EXTERNAL TABLE nyc_tlc_project3.bronze_yellow_taxi (
    vendorid               int,
    tpep_pickup_datetime   timestamp,
    tpep_dropoff_datetime  timestamp,
    passenger_count        bigint,
    trip_distance          double,
    ratecodeid             bigint,
    store_and_fwd_flag     string,
    pulocationid           int,
    dolocationid           int,
    payment_type           bigint,
    fare_amount            double,
    extra                  double,
    mta_tax                double,
    tip_amount             double,
    tolls_amount           double,
    improvement_surcharge  double,
    total_amount           double,
    congestion_surcharge   double,
    airport_fee            double
)
PARTITIONED BY (year string, month string)
ROW FORMAT SERDE 'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT 'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION 's3://<bucket>/bronze/yellow_taxi/'
TBLPROPERTIES ('classification' = 'parquet', 'parquet.compression' = 'SNAPPY');
