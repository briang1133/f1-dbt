{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with drivers as (
    select * from {{ ref('stg_openf1__drivers') }}
),

sessions as (
    select * from {{ ref('stg_openf1__sessions') }}
),

meetings as (
    select * from {{ ref('stg_openf1__meetings') }}
),

results as (
    select * from {{ ref('stg_openf1__results') }}
),

pit_stops as (
    select * from {{ ref('int_team_pit_stops') }}
),

stint_pace as (
    select * from {{ ref('int_stint_pace') }}
),

team_results as (
    select
        drivers.session_key,
        drivers.meeting_key,
        drivers.team_name,
        max(drivers.team_colour_hex) as team_colour_hex,
        cast(count(*) as integer) as drivers_started,
        cast(count(*) filter (where not results.is_dnf and not results.is_dns and not results.is_dsq) as integer)
            as drivers_classified,
        cast(count(*) filter (where results.is_dnf) as integer) as dnf_count,
        cast(count(*) filter (where results.is_dsq) as integer) as dsq_count,
        round(sum(results.points_scored), 1) as team_points_scored,
        cast(min(results.finish_position) as integer) as best_finish_position,
        round(avg(results.finish_position), 2) as avg_finish_position,
        (count(*) filter (where results.points_scored > 0) >= 2) as is_double_points_finish
    from drivers
    inner join results
        on drivers.session_key = results.session_key
        and drivers.driver_number = results.driver_number
    group by
        drivers.session_key,
        drivers.meeting_key,
        drivers.team_name
),

team_pits as (
    select
        session_key,
        team_name,
        cast(count(*) filter (where is_service_stop) as integer) as service_pit_stops,
        round(avg(stop_duration_seconds) filter (where is_service_stop), 3) as avg_stop_duration_seconds,
        round(min(stop_duration_seconds) filter (where is_service_stop), 3) as fastest_stop_duration_seconds,
        round(avg(lane_duration_seconds), 3) as avg_lane_duration_seconds,
        cast(count(*) filter (where pit_execution_tier = 'elite') as integer) as elite_stop_count,
        cast(count(*) filter (where pit_execution_tier = 'slow_or_issue') as integer) as slow_or_issue_stop_count,
        coalesce(min(stop_rank_in_race) = 1, false) as had_race_fastest_stop
    from pit_stops
    group by
        session_key,
        team_name
),

team_stints as (
    select
        session_key,
        team_name,
        cast(count(*) as integer) as total_stints,
        cast(count(distinct compound) as integer) as distinct_compounds_used,
        round(avg(stint_laps), 2) as avg_stint_laps,
        cast(count(*) filter (where is_fresh_tyre) as integer) as fresh_tyre_stints,
        round(avg(avg_clean_lap_seconds), 3) as avg_clean_lap_seconds,
        round(min(fastest_stint_lap_seconds), 3) as fastest_team_lap_seconds,
        cast(max(max_speed_trap_kph) as integer) as max_speed_trap_kph,
        string_agg(distinct compound, ' / ' order by compound) as compounds_used
    from stint_pace
    group by
        session_key,
        team_name
),

final as (
    select
        cast(team_results.session_key as varchar) || '-' || team_results.team_name as team_race_id,
        team_results.session_key,
        team_results.meeting_key,
        meetings.meeting_name,
        sessions.circuit_short_name,
        sessions.country_name,
        sessions.season_year,
        sessions.session_date as race_date,
        team_results.team_name,
        team_results.team_colour_hex,
        team_results.drivers_started,
        team_results.drivers_classified,
        team_results.dnf_count,
        team_results.dsq_count,
        team_results.team_points_scored,
        team_results.best_finish_position,
        team_results.avg_finish_position,
        team_results.is_double_points_finish,
        coalesce(team_pits.service_pit_stops, 0) as service_pit_stops,
        team_pits.avg_stop_duration_seconds,
        team_pits.fastest_stop_duration_seconds,
        team_pits.avg_lane_duration_seconds,
        coalesce(team_pits.elite_stop_count, 0) as elite_stop_count,
        coalesce(team_pits.slow_or_issue_stop_count, 0) as slow_or_issue_stop_count,
        coalesce(team_pits.had_race_fastest_stop, false) as had_race_fastest_stop,
        coalesce(team_stints.total_stints, 0) as total_stints,
        coalesce(team_stints.distinct_compounds_used, 0) as distinct_compounds_used,
        team_stints.avg_stint_laps,
        coalesce(team_stints.fresh_tyre_stints, 0) as fresh_tyre_stints,
        team_stints.avg_clean_lap_seconds,
        team_stints.fastest_team_lap_seconds,
        team_stints.max_speed_trap_kph,
        team_stints.compounds_used
    from team_results
    inner join sessions
        on team_results.session_key = sessions.session_key
    inner join meetings
        on team_results.meeting_key = meetings.meeting_key
    left join team_pits
        on team_results.session_key = team_pits.session_key
        and team_results.team_name = team_pits.team_name
    left join team_stints
        on team_results.session_key = team_stints.session_key
        and team_results.team_name = team_stints.team_name
)

select * from final
