-- Singular test: sum(trips) across agg_hour_of_day must equal the fct_trips row count.
select k.total_trips, f.fct_count
from (select sum(trips) as total_trips from {{ ref('agg_hour_of_day') }}) k
cross join (select count(*) as fct_count from {{ ref('fct_trips') }}) f
where k.total_trips != f.fct_count
