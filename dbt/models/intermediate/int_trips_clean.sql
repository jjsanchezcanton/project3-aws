with trips as (

    select * from {{ ref('stg_yellow_trips') }}

),

cleaned as (

    select *
    from trips
    -- 6 validity flags ported from Project 1's silver_yellow_taxi (thresholds per
    -- the milestone-C spec's explicit numbers; distance/duration caps borrowed
    -- from Project 1 where the spec left them unspecified)
    where pickup_at  < dropoff_at
      and date_diff('second', pickup_at, dropoff_at) <= 21600
      and trip_distance > 0
      and trip_distance <= 100
      and fare_amount  >= 0
      and total_amount >= 0
      and (passenger_count is null or passenger_count between 1 and 8)
      and pickup_location_id  between 1 and 265
      and dropoff_location_id between 1 and 265
      -- a trip must fall within the partition it was ingested into
      and year(pickup_at)  = partition_year
      and month(pickup_at) = partition_month

),

enriched as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'vendor_id', 'pickup_at', 'dropoff_at',
            'pickup_location_id', 'dropoff_location_id', 'total_amount'
        ]) }}                                          as trip_key,

        vendor_id,
        rate_code_id,
        pickup_location_id,
        dropoff_location_id,
        payment_type_id,
        passenger_count,

        pickup_at,
        dropoff_at,
        date(pickup_at)                                as pickup_date,
        hour(pickup_at)                                 as pickup_hour,
        day_of_week(pickup_at)                          as pickup_dow,
        date_diff('minute', pickup_at, dropoff_at)      as trip_duration_min,

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

    from cleaned

),

deduped as (

    select
        trip_key,
        vendor_id,
        rate_code_id,
        pickup_location_id,
        dropoff_location_id,
        payment_type_id,
        passenger_count,
        pickup_at,
        dropoff_at,
        pickup_date,
        pickup_hour,
        pickup_dow,
        trip_duration_min,
        trip_distance,
        fare_amount,
        extra,
        mta_tax,
        tip_amount,
        tolls_amount,
        improvement_surcharge,
        congestion_surcharge,
        airport_fee,
        total_amount,
        row_number() over (partition by trip_key order by pickup_at) as rn
    from enriched

)

select
    trip_key,
    vendor_id,
    rate_code_id,
    pickup_location_id,
    dropoff_location_id,
    payment_type_id,
    passenger_count,
    pickup_at,
    dropoff_at,
    pickup_date,
    pickup_hour,
    pickup_dow,
    trip_duration_min,
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
from deduped
where rn = 1
