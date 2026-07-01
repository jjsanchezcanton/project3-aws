with source as (

    select * from {{ source('bronze', 'bronze_yellow_taxi') }}

),

renamed as (

    select
        vendorid               as vendor_id,
        ratecodeid             as rate_code_id,
        pulocationid           as pickup_location_id,
        dolocationid           as dropoff_location_id,
        payment_type           as payment_type_id,
        store_and_fwd_flag,
        passenger_count,

        cast("year"  as integer) as partition_year,
        cast("month" as integer) as partition_month,

        tpep_pickup_datetime   as pickup_at,
        tpep_dropoff_datetime  as dropoff_at,

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

    from source

)

select * from renamed
