with source as (
    select * from {{ source('openf1', 'session_result') }}
),

renamed as (
    select
        cast(session_key as varchar) || '-' || cast(driver_number as varchar) as result_id,
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        cast(driver_number as integer) as driver_number,
        cast(position as integer) as finish_position,
        cast(number_of_laps as integer) as laps_completed,
        coalesce(cast(points as double), 0.0) as points_scored,
        coalesce(cast(dnf as boolean), false) as is_dnf,
        coalesce(cast(dns as boolean), false) as is_dns,
        coalesce(cast(dsq as boolean), false) as is_dsq,
        cast(duration as double) as race_duration_seconds,
        cast(gap_to_leader as varchar) as gap_to_leader_raw,
        _ingested_at
    from source
)

select * from renamed
