{{ config(materialized='table') }}

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2023-01-01' as date)",
        end_date="cast('2027-01-01' as date)"
    ) }}
),

final as (
    select
        cast(date_day as date)                          as date_key,
        year(date_day)                                  as year,
        month(date_day)                                 as month,
        day(date_day)                                   as day,
        quarter(date_day)                               as quarter,
        day_of_week(date_day)                           as day_of_week,
        date_format(cast(date_day as timestamp), '%W')  as day_name,
        date_format(cast(date_day as timestamp), '%M')  as month_name,
        case when day_of_week(date_day) in (6, 7) then true else false end as is_weekend
    from spine
)

select * from final