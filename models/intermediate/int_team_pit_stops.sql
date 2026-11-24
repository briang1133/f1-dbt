{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with pit_stops as (
    select * from {{ ref('stg_openf1__pit_stops') }}
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

enriched as (
    select
        pit_stops.pit_stop_id,
        pit_stops.session_key,
        pit_stops.meeting_key,
        meetings.meeting_name,
        sessions.circuit_short_name,
        sessions.season_year,
        sessions.session_date,
        pit_stops.pit_entered_at,
        drivers.team_name,
        drivers.team_colour_hex,
        pit_stops.driver_number,
        drivers.driver_acronym,
        drivers.full_name as driver_full_name,
        pit_stops.lap_number,
        pit_stops.stop_duration_seconds,
        pit_stops.lane_duration_seconds,
        pit_stops.pit_duration_seconds,
        (pit_stops.stop_duration_seconds is not null) as is_service_stop,
        case
            when pit_stops.stop_duration_seconds is null then 'not_applicable'
            when pit_stops.stop_duration_seconds < 2.5 then 'elite'
            when pit_stops.stop_duration_seconds < 3.0 then 'fast'
            when pit_stops.stop_duration_seconds < 4.0 then 'standard'
            else 'slow_or_issue'
        end as pit_execution_tier,
        case
            when pit_stops.stop_duration_seconds is not null
                then cast(
                    dense_rank() over (
                        partition by pit_stops.session_key, (pit_stops.stop_duration_seconds is not null)
                        order by pit_stops.stop_duration_seconds asc
                    ) as integer
                )
        end as stop_rank_in_race
    from pit_stops
    inner join drivers
        on pit_stops.session_key = drivers.session_key
        and pit_stops.driver_number = drivers.driver_number
    inner join sessions
        on pit_stops.session_key = sessions.session_key
    inner join meetings
        on pit_stops.meeting_key = meetings.meeting_key
)

select * from enriched
