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

circuit_profiles as (
    select * from {{ ref('circuit_profiles') }}
),

pit_in_laps as (
    select
        session_key,
        driver_number,
        lap_number
    from pit_stops
    group by
        session_key,
        driver_number,
        lap_number
),

session_benchmarks as (
    select
        session_key,
        min(lap_duration_seconds) as fastest_session_lap_seconds,
        max(lap_number) as max_session_lap
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
        laps.lap_number,
        cast(laps.lap_duration_seconds as double) as lap_duration_seconds,
        cast(
            laps.lap_duration_seconds
            - (
                cast(bench.max_session_lap - laps.lap_number as double)
                * cast(coalesce(cp.fuel_effect_s_per_lap, 0.055) as double)
            )
            as double
        ) as fuel_corrected_lap_seconds,
        laps.sector_1_seconds,
        laps.sector_2_seconds,
        laps.sector_3_seconds,
        laps.i1_speed_kph,
        laps.i2_speed_kph,
        laps.speed_trap_kph,
        laps.purple_mini_sectors,
        laps.green_mini_sectors
    from laps
    inner join sessions
        on laps.session_key = sessions.session_key
    inner join session_benchmarks as bench
        on laps.session_key = bench.session_key
    left join circuit_profiles as cp
        on sessions.circuit_short_name = cp.circuit_short_name
    left join pit_in_laps as pit_in
        on laps.session_key = pit_in.session_key
        and laps.driver_number = pit_in.driver_number
        and laps.lap_number = pit_in.lap_number
    where
        laps.lap_duration_seconds is not null
        and laps.lap_number > 1
        and not laps.is_pit_out_lap
        and pit_in.lap_number is null
        and laps.lap_duration_seconds <= bench.fastest_session_lap_seconds * 1.12
),

driver_pace as (
    select
        session_key,
        driver_number,
        cast(count(*) as integer) as clean_lap_count,
        cast(round(avg(lap_duration_seconds), 3) as double) as avg_clean_lap_seconds,
        cast(round(avg(fuel_corrected_lap_seconds), 3) as double) as avg_fuel_corrected_lap_seconds,
        cast(round(median(fuel_corrected_lap_seconds), 3) as double) as median_fuel_corrected_lap_seconds,
        case
            when count(*) >= 5
                then cast(
                    round(
                        quantile_cont(fuel_corrected_lap_seconds, 0.75)
                        - quantile_cont(fuel_corrected_lap_seconds, 0.25),
                        3
                    ) as double
                )
        end as lap_time_iqr_seconds,
        cast(round(avg(sector_1_seconds), 3) as double) as avg_sector_1_seconds,
        cast(round(avg(sector_2_seconds), 3) as double) as avg_sector_2_seconds,
        cast(round(avg(sector_3_seconds), 3) as double) as avg_sector_3_seconds,
        cast(round(avg(i1_speed_kph), 1) as double) as avg_i1_speed_kph,
        cast(round(avg(i2_speed_kph), 1) as double) as avg_i2_speed_kph,
        cast(round(avg(speed_trap_kph), 1) as double) as avg_speed_trap_kph,
        cast(max(speed_trap_kph) as integer) as max_speed_trap_kph,
        cast(coalesce(sum(purple_mini_sectors), 0) as integer) as purple_mini_sector_count,
        cast(coalesce(sum(green_mini_sectors), 0) as integer) as green_mini_sector_count
    from driver_clean_laps
    group by
        session_key,
        driver_number
),

pit_execution as (
    select
        pit_stops.session_key,
        pit_stops.driver_number,
        cast(
            round(
                avg(pit_stops.lane_duration_seconds - pit_stops.stop_duration_seconds)
                filter (where pit_stops.is_service_stop and pit_stops.lane_duration_seconds is not null),
                3
            ) as double
        ) as avg_pit_transit_seconds,
        cast(
            round(
                avg(in_lap.lap_duration_seconds - pace.avg_clean_lap_seconds)
                filter (
                    where in_lap.lap_duration_seconds is not null
                        and in_lap.lap_duration_seconds <= bench.fastest_session_lap_seconds * 1.25
                ),
                3
            ) as double
        ) as avg_in_lap_delta_s,
        cast(
            round(
                avg(out_lap.lap_duration_seconds - pace.avg_clean_lap_seconds)
                filter (
                    where out_lap.lap_duration_seconds is not null
                        and out_lap.lap_duration_seconds <= bench.fastest_session_lap_seconds * 1.35
                ),
                3
            ) as double
        ) as avg_out_lap_delta_s
    from pit_stops
    inner join session_benchmarks as bench
        on pit_stops.session_key = bench.session_key
    left join driver_pace as pace
        on pit_stops.session_key = pace.session_key
        and pit_stops.driver_number = pace.driver_number
    left join laps as in_lap
        on pit_stops.session_key = in_lap.session_key
        and pit_stops.driver_number = in_lap.driver_number
        and pit_stops.lap_number = in_lap.lap_number
    left join laps as out_lap
        on pit_stops.session_key = out_lap.session_key
        and pit_stops.driver_number = out_lap.driver_number
        and pit_stops.lap_number + 1 = out_lap.lap_number
    where pit_stops.is_service_stop
    group by
        pit_stops.session_key,
        pit_stops.driver_number
),

joined as (
    select
        results.result_id as driver_race_id,
        results.session_key,
        results.meeting_key,
        meetings.meeting_name,
        sessions.circuit_short_name,
        sessions.season_year,
        sessions.session_date as race_date,
        drivers.team_name,
        drivers.team_colour_hex,
        results.driver_number,
        drivers.driver_acronym,
        drivers.full_name as driver_full_name,
        results.finish_position,
        coalesce(pace.clean_lap_count, 0) as clean_lap_count,
        pace.avg_clean_lap_seconds,
        pace.avg_fuel_corrected_lap_seconds,
        pace.median_fuel_corrected_lap_seconds,
        pace.lap_time_iqr_seconds,
        pace.avg_sector_1_seconds,
        pace.avg_sector_2_seconds,
        pace.avg_sector_3_seconds,
        pace.avg_i1_speed_kph,
        pace.avg_i2_speed_kph,
        pace.avg_speed_trap_kph,
        pace.max_speed_trap_kph,
        coalesce(pace.purple_mini_sector_count, 0) as purple_mini_sector_count,
        coalesce(pace.green_mini_sector_count, 0) as green_mini_sector_count,
        pit_exec.avg_pit_transit_seconds,
        pit_exec.avg_in_lap_delta_s,
        pit_exec.avg_out_lap_delta_s
    from results
    inner join drivers
        on results.session_key = drivers.session_key
        and results.driver_number = drivers.driver_number
    inner join sessions
        on results.session_key = sessions.session_key
    inner join meetings
        on results.meeting_key = meetings.meeting_key
    left join driver_pace as pace
        on results.session_key = pace.session_key
        and results.driver_number = pace.driver_number
    left join pit_execution as pit_exec
        on results.session_key = pit_exec.session_key
        and results.driver_number = pit_exec.driver_number
),

with_team_and_field_benchmarks as (
    select
        *,
        cast(
            count(*) filter (where clean_lap_count >= 5) over (
                partition by session_key, team_name
            ) as integer
        ) as teammates_with_pace_count,
        min(case when clean_lap_count >= 5 then avg_fuel_corrected_lap_seconds end) over (
            partition by session_key, team_name
        ) as team_best_fc_lap_seconds,
        min(case when clean_lap_count >= 5 then avg_fuel_corrected_lap_seconds end) over (
            partition by session_key
        ) as session_best_car_fc_lap_seconds,
        row_number() over (
            partition by session_key, team_name
            order by
                case when clean_lap_count >= 5 then 0 else 1 end asc,
                avg_fuel_corrected_lap_seconds asc nulls last,
                finish_position asc nulls last,
                driver_number asc
        ) as team_pace_rank
    from joined
),

with_lead_sectors as (
    select
        *,
        max(case when team_pace_rank = 1 then avg_sector_1_seconds end) over (
            partition by session_key, team_name
        ) as team_lead_s1_seconds,
        max(case when team_pace_rank = 1 then avg_sector_2_seconds end) over (
            partition by session_key, team_name
        ) as team_lead_s2_seconds,
        max(case when team_pace_rank = 1 then avg_sector_3_seconds end) over (
            partition by session_key, team_name
        ) as team_lead_s3_seconds
    from with_team_and_field_benchmarks
),

final as (
    select
        driver_race_id,
        session_key,
        meeting_key,
        meeting_name,
        circuit_short_name,
        season_year,
        race_date,
        team_name,
        team_colour_hex,
        driver_number,
        driver_acronym,
        driver_full_name,
        finish_position,
        clean_lap_count,
        avg_clean_lap_seconds,
        avg_fuel_corrected_lap_seconds,
        median_fuel_corrected_lap_seconds,
        lap_time_iqr_seconds,
        avg_sector_1_seconds,
        avg_sector_2_seconds,
        avg_sector_3_seconds,
        avg_i1_speed_kph,
        avg_i2_speed_kph,
        avg_speed_trap_kph,
        max_speed_trap_kph,
        purple_mini_sector_count,
        green_mini_sector_count,
        avg_pit_transit_seconds,
        avg_in_lap_delta_s,
        avg_out_lap_delta_s,
        teammates_with_pace_count,
        (team_pace_rank = 1 and clean_lap_count >= 5) as is_faster_teammate,
        team_best_fc_lap_seconds,
        cast(
            round(team_best_fc_lap_seconds - session_best_car_fc_lap_seconds, 3)
            as double
        ) as car_pace_deficit_s,
        cast(
            round(
                (team_best_fc_lap_seconds - session_best_car_fc_lap_seconds)
                / nullif(session_best_car_fc_lap_seconds, 0),
                5
            ) as double
        ) as car_pace_deficit_pct,
        case
            when clean_lap_count >= 5 and team_best_fc_lap_seconds is not null
                then cast(round(avg_fuel_corrected_lap_seconds - team_best_fc_lap_seconds, 3) as double)
        end as driver_delta_vs_teammate_s,
        case
            when clean_lap_count >= 5
                then cast(round(avg_sector_1_seconds - team_lead_s1_seconds, 3) as double)
        end as s1_delta_vs_teammate_s,
        case
            when clean_lap_count >= 5
                then cast(round(avg_sector_2_seconds - team_lead_s2_seconds, 3) as double)
        end as s2_delta_vs_teammate_s,
        case
            when clean_lap_count >= 5
                then cast(round(avg_sector_3_seconds - team_lead_s3_seconds, 3) as double)
        end as s3_delta_vs_teammate_s
    from with_lead_sectors
)

select * from final
