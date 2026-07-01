select
    pickup_hour,
    pickup_dow,
    count(*) as trips
from {{ ref('fct_trips') }}
group by pickup_hour, pickup_dow
