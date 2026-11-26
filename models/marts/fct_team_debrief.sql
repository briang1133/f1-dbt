{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with team_perf as (
    select * from {{ ref('fct_team_race_performance') }}
),

teammates as (
    select * from {{ ref('int_teammate_benchmark') }}
),

stint_deg as (
    select * from {{ ref('int_stint_degradation') }}
),

circuit_profiles as (
    select * from {{ ref('circuit_profiles') }}
),

team_driver_agg as (
    select
        session_key,
        team_name,
        max(case when is_faster_teammate then driver_acronym end) as lead_driver_acronym,
        max(case when not is_faster_teammate and clean_lap_count >= 5 then driver_acronym end)
            as second_driver_acronym,
        cast(round(min(car_pace_deficit_s), 3) as double) as car_pace_deficit_s,
        cast(round(min(car_pace_deficit_pct), 5) as double) as car_pace_deficit_pct,
        cast(
            round(
                max(driver_delta_vs_teammate_s) filter (where not is_faster_teammate and clean_lap_count >= 5),
                3
            ) as double
        ) as teammate_pace_spread_s,
        cast(round(avg(lap_time_iqr_seconds), 3) as double) as avg_driver_consistency_iqr_s,
        cast(round(avg(avg_i1_speed_kph), 1) as double) as avg_i1_speed_kph,
        cast(round(avg(avg_i2_speed_kph), 1) as double) as avg_i2_speed_kph,
        cast(round(avg(avg_speed_trap_kph), 1) as double) as avg_speed_trap_kph,
        cast(coalesce(sum(purple_mini_sector_count), 0) as integer) as total_purple_mini_sectors,
        cast(round(avg(avg_pit_transit_seconds), 3) as double) as avg_pit_transit_seconds,
        cast(round(avg(avg_in_lap_delta_s), 3) as double) as avg_in_lap_delta_s,
        cast(round(avg(avg_out_lap_delta_s), 3) as double) as avg_out_lap_delta_s
    from teammates
    group by
        session_key,
        team_name
),

team_deg_agg as (
    select
        session_key,
        team_name,
        cast(count(*) filter (where deg_slope_s_per_lap is not null) as integer) as measured_deg_stints,
        cast(round(avg(deg_slope_s_per_lap), 4) as double) as avg_deg_slope_s_per_lap,
        cast(round(avg(deg_slope_s_per_lap) filter (where compound = 'HARD'), 4) as double)
            as hard_deg_slope_s_per_lap,
        cast(round(avg(deg_slope_s_per_lap) filter (where compound = 'MEDIUM'), 4) as double)
            as medium_deg_slope_s_per_lap,
        cast(round(avg(deg_slope_s_per_lap) filter (where compound = 'SOFT'), 4) as double)
            as soft_deg_slope_s_per_lap,
        cast(round(avg(stint_pace_dropoff_s), 3) as double) as avg_stint_dropoff_s
    from stint_deg
    group by
        session_key,
        team_name
),

joined as (
    select
        tp.team_race_id,
        tp.session_key,
        tp.meeting_key,
        tp.meeting_name,
        tp.circuit_short_name,
        coalesce(cp.circuit_archetype, 'unknown') as circuit_archetype,
        coalesce(cp.downforce_level, 'unknown') as downforce_level,
        coalesce(cp.tyre_deg_severity, 'unknown') as tyre_deg_severity,
        coalesce(cp.overtaking_difficulty, 'unknown') as overtaking_difficulty,
        cp.pirelli_hard_spec,
        cp.pirelli_medium_spec,
        cp.pirelli_soft_spec,
        tp.season_year,
        tp.race_date,
        tp.team_name,
        tp.team_colour_hex,
        tp.team_points_scored,
        tp.best_finish_position,
        tp.dnf_count,
        tp.service_pit_stops,
        tp.avg_stop_duration_seconds,
        tp.slow_or_issue_stop_count,
        tp.max_speed_trap_kph,
        td.lead_driver_acronym,
        td.second_driver_acronym,
        td.car_pace_deficit_s,
        td.car_pace_deficit_pct,
        td.teammate_pace_spread_s,
        td.avg_driver_consistency_iqr_s,
        td.avg_i1_speed_kph,
        td.avg_i2_speed_kph,
        td.avg_speed_trap_kph,
        coalesce(td.total_purple_mini_sectors, 0) as total_purple_mini_sectors,
        td.avg_pit_transit_seconds,
        td.avg_in_lap_delta_s,
        td.avg_out_lap_delta_s,
        coalesce(deg.measured_deg_stints, 0) as measured_deg_stints,
        deg.avg_deg_slope_s_per_lap,
        deg.hard_deg_slope_s_per_lap,
        deg.medium_deg_slope_s_per_lap,
        deg.soft_deg_slope_s_per_lap,
        deg.avg_stint_dropoff_s
    from team_perf as tp
    left join circuit_profiles as cp
        on tp.circuit_short_name = cp.circuit_short_name
    left join team_driver_agg as td
        on tp.session_key = td.session_key
        and tp.team_name = td.team_name
    left join team_deg_agg as deg
        on tp.session_key = deg.session_key
        and tp.team_name = deg.team_name
),

with_session_context as (
    select
        *,
        case
            when car_pace_deficit_s is not null
                then cast(
                    dense_rank() over (
                        partition by session_key, (car_pace_deficit_s is not null)
                        order by car_pace_deficit_s asc
                    ) as integer
                )
        end as car_pace_rank,
        cast(
            round(
                avg_speed_trap_kph - avg(avg_speed_trap_kph) over (partition by session_key),
                1
            ) as double
        ) as speed_trap_delta_vs_field_kph,
        cast(
            round(
                avg_deg_slope_s_per_lap - median(avg_deg_slope_s_per_lap) over (partition by session_key),
                4
            ) as double
        ) as deg_delta_vs_field_s_per_lap,
        cast(
            round(
                avg_stop_duration_seconds - min(avg_stop_duration_seconds) over (partition by session_key),
                3
            ) as double
        ) as pit_stop_delta_vs_best_team_s
    from joined
),

final as (
    select
        team_race_id,
        session_key,
        meeting_key,
        meeting_name,
        circuit_short_name,
        circuit_archetype,
        downforce_level,
        tyre_deg_severity,
        overtaking_difficulty,
        pirelli_hard_spec,
        pirelli_medium_spec,
        pirelli_soft_spec,
        season_year,
        race_date,
        team_name,
        team_colour_hex,
        team_points_scored,
        best_finish_position,
        dnf_count,
        service_pit_stops,
        avg_stop_duration_seconds,
        slow_or_issue_stop_count,
        pit_stop_delta_vs_best_team_s,
        avg_pit_transit_seconds,
        avg_in_lap_delta_s,
        avg_out_lap_delta_s,
        car_pace_rank,
        car_pace_deficit_s,
        car_pace_deficit_pct,
        avg_i1_speed_kph,
        avg_i2_speed_kph,
        avg_speed_trap_kph,
        max_speed_trap_kph,
        speed_trap_delta_vs_field_kph,
        total_purple_mini_sectors,
        measured_deg_stints,
        avg_deg_slope_s_per_lap,
        deg_delta_vs_field_s_per_lap,
        hard_deg_slope_s_per_lap,
        medium_deg_slope_s_per_lap,
        soft_deg_slope_s_per_lap,
        avg_stint_dropoff_s,
        lead_driver_acronym,
        second_driver_acronym,
        teammate_pace_spread_s,
        avg_driver_consistency_iqr_s,
        case
            when dnf_count > 0 or slow_or_issue_stop_count > 0
                then 'Pit / Reliability Execution'
            when car_pace_deficit_pct is not null and car_pace_deficit_pct >= 0.012
                then 'Car Pace Deficit'
            when deg_delta_vs_field_s_per_lap is not null and deg_delta_vs_field_s_per_lap >= 0.025
                then 'High Tire Degradation'
            when teammate_pace_spread_s is not null and teammate_pace_spread_s >= 0.40
                then 'Driver Pace Spread'
            else 'Benchmark Execution'
        end as primary_focus_area
    from with_session_context
)

select * from final
