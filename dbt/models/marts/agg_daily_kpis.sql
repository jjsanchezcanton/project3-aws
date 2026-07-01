select
    pickup_date                                                          as trip_date,
    count(*)                                                             as trips,
    sum(total_amount)                                                    as total_revenue,
    avg(fare_amount)                                                     as avg_fare,
    100.0 * sum(case when payment_type_id = 1 then 1 else 0 end) / count(*) as pct_paid_by_card
from {{ ref('fct_trips') }}
group by pickup_date
