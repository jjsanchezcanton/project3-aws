with source as (

    select * from {{ ref('taxi_zones') }}

)

select
    locationid    as zone_id,
    borough,
    zone          as zone_name,
    service_zone
from source
