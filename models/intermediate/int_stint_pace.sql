{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with stints as (
    select * from {{ ref('stg_openf1__stints') }}
),

laps as (
    select * from {{ ref('stg_openf1__laps') }}
),

drivers as (
    select * from {{ ref('stg_openf1__drivers') }}
),

sessions as (
    select * from {{ ref('stg_openf1__sessions') }}
),

meetings as (
    select * from {{ ref('stg_openf1__meetings') }}
),

session_pace_benchmark as (
    select
        session_key,
        min(lap_duration_seconds) as fastest_session_lap_seconds
    from laps
    where
        lap_duration_seconds is not null
        and lap_number > 1
        and not is_pit_out_lap
    group by session_key
),

stint_clean_laps as (
    select
        stints.stint_id,
        laps.lap_number,
        laps.lap_duration_seconds,
        laps.speed_trap_kph
    from stints
    inner join laps
        on stints.session_key = laps.session_key
        and stints.driver_number = laps.driver_number
        and laps.lap_number between stints.lap_start and stints.lap_end
    inner join session_pace_benchmark as benchmark
        on stints.session_key = benchmark.session_key
    where
        laps.lap_duration_seconds is not null
        and laps.lap_number > 1
        and not laps.is_pit_out_lap
        -- Exclude Safety Car / VSC laps (>12% slower than the race's fastest lap)
        and laps.lap_duration_seconds <= benchmark.fastest_session_lap_seconds * 1.12
),

stint_lap_metrics as (
    select
        stint_id,
        cast(count(*) as integer) as clean_lap_count,
        round(avg(lap_duration_seconds), 3) as avg_clean_lap_seconds,
        round(min(lap_duration_seconds), 3) as fastest_stint_lap_seconds,
        cast(max(speed_trap_kph) as integer) as max_speed_trap_kph
    from stint_clean_laps
    group by stint_id
),

final as (
    select
        stints.stint_id,
        stints.session_key,
        stints.meeting_key,
        meetings.meeting_name,
        sessions.circuit_short_name,
        sessions.season_year,
        sessions.session_date,
        drivers.team_name,
        drivers.team_colour_hex,
        stints.driver_number,
        drivers.driver_acronym,
        stints.stint_number,
        stints.compound,
        stints.lap_start,
        stints.lap_end,
        stints.stint_laps,
        stints.tyre_age_at_start,
        stints.is_fresh_tyre,
        coalesce(metrics.clean_lap_count, 0) as clean_lap_count,
        metrics.avg_clean_lap_seconds,
        metrics.fastest_stint_lap_seconds,
        metrics.max_speed_trap_kph
    from stints
    inner join drivers
        on stints.session_key = drivers.session_key
        and stints.driver_number = drivers.driver_number
    inner join sessions
        on stints.session_key = sessions.session_key
    inner join meetings
        on stints.meeting_key = meetings.meeting_key
    left join stint_lap_metrics as metrics
        on stints.stint_id = metrics.stint_id
)

select * from final
