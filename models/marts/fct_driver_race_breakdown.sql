{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with results as (
    select * from {{ ref('stg_openf1__results') }}
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

laps as (
    select * from {{ ref('stg_openf1__laps') }}
),

pit_stops as (
    select * from {{ ref('int_team_pit_stops') }}
),

stints as (
    select * from {{ ref('stg_openf1__stints') }}
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

driver_clean_laps as (
    select
        laps.session_key,
        laps.driver_number,
        cast(count(*) as integer) as clean_lap_count,
        round(avg(laps.lap_duration_seconds), 3) as avg_clean_lap_seconds,
        round(min(laps.lap_duration_seconds), 3) as fastest_lap_seconds,
        round(avg(laps.sector_1_seconds), 3) as avg_sector_1_seconds,
        round(avg(laps.sector_2_seconds), 3) as avg_sector_2_seconds,
        round(avg(laps.sector_3_seconds), 3) as avg_sector_3_seconds,
        cast(max(laps.speed_trap_kph) as integer) as max_speed_trap_kph
    from laps
    inner join session_pace_benchmark as bench
        on laps.session_key = bench.session_key
    where
        laps.lap_duration_seconds is not null
        and laps.lap_number > 1
        and not laps.is_pit_out_lap
        and laps.lap_duration_seconds <= bench.fastest_session_lap_seconds * 1.12
    group by
        laps.session_key,
        laps.driver_number
),

driver_pits as (
    select
        session_key,
        driver_number,
        cast(count(*) as integer) as pit_stop_count,
        cast(count(*) filter (where is_service_stop) as integer) as service_pit_stops,
        round(avg(stop_duration_seconds) filter (where is_service_stop), 2) as avg_stop_duration_seconds,
        round(min(stop_duration_seconds) filter (where is_service_stop), 2) as fastest_stop_duration_seconds,
        round(sum(lane_duration_seconds), 2) as total_pit_lane_seconds
    from pit_stops
    group by
        session_key,
        driver_number
),

driver_stints as (
    select
        session_key,
        driver_number,
        cast(count(*) as integer) as stint_count,
        string_agg(
            compound || ' (' || cast(stint_laps as varchar) || 'L)',
            ' -> '
            order by stint_number
        ) as tyre_strategy,
        string_agg(distinct compound, ' / ' order by compound) as compounds_used
    from stints
    group by
        session_key,
        driver_number
),

joined as (
    select
        results.result_id as driver_race_id,
        results.session_key,
        results.meeting_key,
        meetings.meeting_name,
        sessions.circuit_short_name,
        sessions.country_name,
        sessions.season_year,
        sessions.session_date as race_date,
        results.driver_number,
        drivers.driver_acronym,
        drivers.full_name as driver_full_name,
        drivers.team_name,
        drivers.team_colour_hex,
        results.finish_position,
        coalesce(results.finish_position = 1, false) as is_winner,
        results.laps_completed,
        results.points_scored,
        results.is_dnf,
        results.is_dns,
        results.is_dsq,
        try_cast(results.gap_to_leader_raw as double) as gap_to_leader_seconds,
        coalesce(clean_laps.clean_lap_count, 0) as clean_lap_count,
        clean_laps.avg_clean_lap_seconds,
        clean_laps.fastest_lap_seconds,
        clean_laps.avg_sector_1_seconds,
        clean_laps.avg_sector_2_seconds,
        clean_laps.avg_sector_3_seconds,
        clean_laps.max_speed_trap_kph,
        coalesce(pits.pit_stop_count, 0) as pit_stop_count,
        coalesce(pits.service_pit_stops, 0) as service_pit_stops,
        pits.avg_stop_duration_seconds,
        pits.fastest_stop_duration_seconds,
        pits.total_pit_lane_seconds,
        coalesce(stints_agg.stint_count, 0) as stint_count,
        stints_agg.tyre_strategy,
        stints_agg.compounds_used
    from results
    inner join drivers
        on results.session_key = drivers.session_key
        and results.driver_number = drivers.driver_number
    inner join sessions
        on results.session_key = sessions.session_key
    inner join meetings
        on results.meeting_key = meetings.meeting_key
    left join driver_clean_laps as clean_laps
        on results.session_key = clean_laps.session_key
        and results.driver_number = clean_laps.driver_number
    left join driver_pits as pits
        on results.session_key = pits.session_key
        and results.driver_number = pits.driver_number
    left join driver_stints as stints_agg
        on results.session_key = stints_agg.session_key
        and results.driver_number = stints_agg.driver_number
),

with_benchmarks as (
    select
        *,
        max(case when finish_position = 1 then avg_clean_lap_seconds end)
            over (partition by session_key) as winner_avg_lap_seconds,
        max(case when finish_position = 1 then avg_sector_1_seconds end)
            over (partition by session_key) as winner_s1_seconds,
        max(case when finish_position = 1 then avg_sector_2_seconds end)
            over (partition by session_key) as winner_s2_seconds,
        max(case when finish_position = 1 then avg_sector_3_seconds end)
            over (partition by session_key) as winner_s3_seconds,
        max(case when finish_position = 1 then total_pit_lane_seconds end)
            over (partition by session_key) as winner_pit_lane_seconds,
        max(case when finish_position = 2 then gap_to_leader_seconds end)
            over (partition by session_key) as winning_margin_seconds,
        max(case when finish_position = 2 then avg_clean_lap_seconds end)
            over (partition by session_key) as p2_avg_lap_seconds,
        max(case when finish_position = 2 then avg_sector_1_seconds end)
            over (partition by session_key) as p2_s1_seconds,
        max(case when finish_position = 2 then avg_sector_2_seconds end)
            over (partition by session_key) as p2_s2_seconds,
        max(case when finish_position = 2 then avg_sector_3_seconds end)
            over (partition by session_key) as p2_s3_seconds,
        max(case when finish_position = 2 then total_pit_lane_seconds end)
            over (partition by session_key) as p2_pit_lane_seconds
    from joined
),

final as (
    select
        driver_race_id,
        session_key,
        meeting_key,
        meeting_name,
        circuit_short_name,
        country_name,
        season_year,
        race_date,
        driver_number,
        driver_acronym,
        driver_full_name,
        team_name,
        team_colour_hex,
        finish_position,
        is_winner,
        laps_completed,
        points_scored,
        is_dnf,
        is_dns,
        is_dsq,
        gap_to_leader_seconds,
        winning_margin_seconds,
        clean_lap_count,
        avg_clean_lap_seconds,
        fastest_lap_seconds,
        avg_sector_1_seconds,
        avg_sector_2_seconds,
        avg_sector_3_seconds,
        max_speed_trap_kph,
        pit_stop_count,
        service_pit_stops,
        avg_stop_duration_seconds,
        fastest_stop_duration_seconds,
        total_pit_lane_seconds,
        stint_count,
        tyre_strategy,
        compounds_used,
        round(avg_clean_lap_seconds - winner_avg_lap_seconds, 3) as delta_vs_winner_avg_lap_s,
        round(avg_sector_1_seconds - winner_s1_seconds, 3) as delta_vs_winner_s1_s,
        round(avg_sector_2_seconds - winner_s2_seconds, 3) as delta_vs_winner_s2_s,
        round(avg_sector_3_seconds - winner_s3_seconds, 3) as delta_vs_winner_s3_s,
        round(total_pit_lane_seconds - winner_pit_lane_seconds, 2) as delta_vs_winner_pit_lane_s,
        round(winner_avg_lap_seconds - p2_avg_lap_seconds, 3) as winner_vs_p2_avg_lap_s,
        round(winner_s1_seconds - p2_s1_seconds, 3) as winner_vs_p2_s1_s,
        round(winner_s2_seconds - p2_s2_seconds, 3) as winner_vs_p2_s2_s,
        round(winner_s3_seconds - p2_s3_seconds, 3) as winner_vs_p2_s3_s,
        round(winner_pit_lane_seconds - p2_pit_lane_seconds, 2) as winner_vs_p2_pit_lane_s
    from with_benchmarks
)

select * from final
