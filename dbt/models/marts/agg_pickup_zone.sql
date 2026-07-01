with trips as (

    select * from {{ ref('fct_trips') }}

),

zones as (

    select * from {{ ref('dim_zone') }}

)

select
    z.zone_id,
    z.borough,
    z.zone_name,
    count(*)             as trips,
    sum(t.total_amount)  as revenue
from trips t
join zones z on t.pickup_location_id = z.zone_id
group by z.zone_id, z.borough, z.zone_name
