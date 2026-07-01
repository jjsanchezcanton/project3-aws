{{
    config(
        materialized='incremental',
        table_type='iceberg',
        incremental_strategy='merge',
        unique_key='trip_key',
        format='parquet',
        on_schema_change='append_new_columns'
    )
}}

with trips as (

    select * from {{ ref('int_trips_clean') }}

)

select
    trip_key,

    -- foreign keys
    pickup_date,
    vendor_id,
    rate_code_id,
    pickup_location_id,
    dropoff_location_id,
    payment_type_id,

    -- degenerate / context
    pickup_at,
    dropoff_at,
    pickup_hour,
    pickup_dow,
    passenger_count,
    trip_duration_min,

    -- measures
    trip_distance,
    fare_amount,
    extra,
    mta_tax,
    tip_amount,
    tolls_amount,
    improvement_surcharge,
    congestion_surcharge,
    airport_fee,
    total_amount

from trips

{% if is_incremental() %}
-- only process trips newer than what's already loaded (watermark)
where pickup_at > (select max(pickup_at) from {{ this }})
{% endif %}
