# Bronze external table (ADR-009). Schema verified against the real
# yellow_tripdata_2024-01.parquet file (see sql/ddl/bronze_yellow_taxi.sql header) —
# vendorid/pulocationid/dolocationid are int32, passenger_count/ratecodeid/payment_type
# are int64 in this month's file, despite TLC's known drift to double in other months.
resource "aws_glue_catalog_table" "bronze_yellow_taxi" {
  name          = "bronze_yellow_taxi"
  database_name = aws_glue_catalog_database.db.name
  table_type    = "EXTERNAL_TABLE"

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  parameters = {
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.bucket}/bronze/yellow_taxi/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "vendorid"
      type = "int"
    }
    columns {
      name = "tpep_pickup_datetime"
      type = "timestamp"
    }
    columns {
      name = "tpep_dropoff_datetime"
      type = "timestamp"
    }
    columns {
      name = "passenger_count"
      type = "bigint"
    }
    columns {
      name = "trip_distance"
      type = "double"
    }
    columns {
      name = "ratecodeid"
      type = "bigint"
    }
    columns {
      name = "store_and_fwd_flag"
      type = "string"
    }
    columns {
      name = "pulocationid"
      type = "int"
    }
    columns {
      name = "dolocationid"
      type = "int"
    }
    columns {
      name = "payment_type"
      type = "bigint"
    }
    columns {
      name = "fare_amount"
      type = "double"
    }
    columns {
      name = "extra"
      type = "double"
    }
    columns {
      name = "mta_tax"
      type = "double"
    }
    columns {
      name = "tip_amount"
      type = "double"
    }
    columns {
      name = "tolls_amount"
      type = "double"
    }
    columns {
      name = "improvement_surcharge"
      type = "double"
    }
    columns {
      name = "total_amount"
      type = "double"
    }
    columns {
      name = "congestion_surcharge"
      type = "double"
    }
    columns {
      name = "airport_fee"
      type = "double"
    }
  }
}
