with source as (
    select * from {{ source('openf1', 'pit') }}
),

renamed as (
    select
        cast(session_key as varchar)
            || '-' || cast(driver_number as varchar)
            || '-' || cast(lap_number as varchar) as pit_stop_id,
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        cast(driver_number as integer) as driver_number,
        cast(lap_number as integer) as lap_number,
        cast(date as timestamp) as pit_entered_at,
        cast(stop_duration as double) as stop_duration_seconds,
        cast(lane_duration as double) as lane_duration_seconds,
        cast(pit_duration as double) as pit_duration_seconds,
        _ingested_at
    from source
)

select * from renamed
