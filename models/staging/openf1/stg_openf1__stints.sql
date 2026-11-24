with source as (
    select * from {{ source('openf1', 'stints') }}
),

renamed as (
    select
        cast(session_key as varchar)
            || '-' || cast(driver_number as varchar)
            || '-' || cast(stint_number as varchar) as stint_id,
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        cast(driver_number as integer) as driver_number,
        cast(stint_number as integer) as stint_number,
        upper(trim(compound)) as compound,
        cast(lap_start as integer) as lap_start,
        cast(lap_end as integer) as lap_end,
        cast(lap_end - lap_start + 1 as integer) as stint_laps,
        cast(tyre_age_at_start as integer) as tyre_age_at_start,
        coalesce(tyre_age_at_start = 0, false) as is_fresh_tyre,
        _ingested_at
    from source
)

select * from renamed
