with source as (
    select * from {{ source('openf1', 'laps') }}
),

renamed as (
    select
        cast(session_key as varchar)
            || '-' || cast(driver_number as varchar)
            || '-' || cast(lap_number as varchar) as lap_id,
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        cast(driver_number as integer) as driver_number,
        cast(lap_number as integer) as lap_number,
        cast(date_start as timestamp) as lap_started_at,
        cast(lap_duration as double) as lap_duration_seconds,
        cast(duration_sector_1 as double) as sector_1_seconds,
        cast(duration_sector_2 as double) as sector_2_seconds,
        cast(duration_sector_3 as double) as sector_3_seconds,
        cast(st_speed as integer) as speed_trap_kph,
        cast(i1_speed as integer) as i1_speed_kph,
        cast(i2_speed as integer) as i2_speed_kph,
        coalesce(cast(is_pit_out_lap as boolean), false) as is_pit_out_lap,
        _ingested_at
    from source
)

select * from renamed
