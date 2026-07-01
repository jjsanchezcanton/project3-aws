-- Singular test: total_amount vs the sum of its fare components.
--
-- Severity is WARN by design: the TLC source has documented discrepancies in
-- total_amount (notably how congestion_surcharge is reflected). This is upstream
-- data quality we cannot fix; failing the build on it would be wrong. Instead we
-- SURFACE and MONITOR the discrepancy rate. The returned row count is itself the
-- data-quality signal we report. See ADR-016.
{{ config(severity='warn') }}

select
    trip_key,
    total_amount,
    round(
          fare_amount + extra + mta_tax + tip_amount + tolls_amount
        + improvement_surcharge + congestion_surcharge + airport_fee
    , 2)                                          as computed_total,
    abs(total_amount - (
          fare_amount + extra + mta_tax + tip_amount + tolls_amount
        + improvement_surcharge + congestion_surcharge + airport_fee
    ))                                            as diff
from {{ ref('fct_trips') }}
where abs(total_amount - (
          fare_amount + extra + mta_tax + tip_amount + tolls_amount
        + improvement_surcharge + congestion_surcharge + airport_fee
    )) > 0.01
