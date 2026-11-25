{{
    config(
        materialized='incremental',
        incremental_strategy='microbatch',
        event_time='lap_started_at',
        batch_size='month',
        begin='2025-03-01',
        on_schema_change='append_new_columns',
    )
}}

with laps as (
    -- Microbatch automatically injects time-window filters on stg_openf1__laps
    -- using its configured event_time (lap_started_at).
    select * from {{ ref('stg_openf1__laps') }}
    where lap_started_at is not null
),

drivers as (
    select * from {{ ref('stg_openf1__drivers') }}
),

sessions as (
    select * from {{ ref('stg_openf1__sessions') }}
),

stints as (
    select * from {{ ref('stg_openf1__stints') }}
),

final as (
    select
        laps.lap_id,
        laps.session_key,
        laps.meeting_key,
        sessions.circuit_short_name,
        sessions.season_year,
        sessions.session_date as race_date,
        laps.lap_started_at,
        drivers.team_name,
        drivers.driver_number,
        drivers.driver_acronym,
        laps.lap_number,
        stints.stint_number,
        stints.compound,
        laps.lap_duration_seconds,
        laps.sector_1_seconds,
        laps.sector_2_seconds,
        laps.sector_3_seconds,
        laps.i1_speed_kph,
        laps.i2_speed_kph,
        laps.speed_trap_kph,
        laps.purple_mini_sectors,
        laps.is_pit_out_lap
    from laps
    inner join drivers
        on laps.session_key = drivers.session_key
        and laps.driver_number = drivers.driver_number
    inner join sessions
        on laps.session_key = sessions.session_key
    left join stints
        on laps.session_key = stints.session_key
        and laps.driver_number = stints.driver_number
        and laps.lap_number between stints.lap_start and stints.lap_end
    -- Guard against overlapping stint boundaries (e.g. wet-race red flags/safety cars)
    qualify row_number() over (
        partition by laps.lap_id
        order by stints.stint_number desc
    ) = 1
)

select * from final
