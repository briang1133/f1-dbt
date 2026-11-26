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

pit_stops as (
    select
        session_key,
        driver_number,
        lap_number
    from {{ ref('stg_openf1__pit_stops') }}
    group by
        session_key,
        driver_number,
        lap_number
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

circuit_profiles as (
    select * from {{ ref('circuit_profiles') }}
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

stint_clean_laps as (
    select
        stints.stint_id,
        stints.session_key,
        laps.lap_number,
        cast(stints.tyre_age_at_start + (laps.lap_number - stints.lap_start) as integer) as tyre_age_lap,
        cast(laps.lap_duration_seconds as double) as lap_duration_seconds,
        cast(
            laps.lap_duration_seconds
            - (
                cast(bench.max_session_lap - laps.lap_number as double)
                * cast(coalesce(cp.fuel_effect_s_per_lap, 0.055) as double)
            )
            as double
        ) as fuel_corrected_lap_seconds,
        laps.purple_mini_sectors,
        row_number() over (
            partition by stints.stint_id
            order by laps.lap_number asc
        ) as stint_clean_lap_seq_asc,
        row_number() over (
            partition by stints.stint_id
            order by laps.lap_number desc
        ) as stint_clean_lap_seq_desc
    from stints
    inner join laps
        on stints.session_key = laps.session_key
        and stints.driver_number = laps.driver_number
        and laps.lap_number between stints.lap_start and stints.lap_end
    inner join sessions
        on stints.session_key = sessions.session_key
    inner join session_benchmarks as bench
        on stints.session_key = bench.session_key
    left join circuit_profiles as cp
        on sessions.circuit_short_name = cp.circuit_short_name
    left join pit_stops as pit_in
        on laps.session_key = pit_in.session_key
        and laps.driver_number = pit_in.driver_number
        and laps.lap_number = pit_in.lap_number
    where
        laps.lap_duration_seconds is not null
        and laps.lap_number > 1
        and not laps.is_pit_out_lap
        -- Exclude pit in-laps so pit-entry deceleration does not distort degradation slopes
        and pit_in.lap_number is null
        -- Exclude Safety Car / VSC laps (>12% slower than fastest lap)
        and laps.lap_duration_seconds <= bench.fastest_session_lap_seconds * 1.12
),

stint_deg_metrics as (
    select
        stint_id,
        cast(count(*) as integer) as clean_lap_count,
        cast(round(avg(lap_duration_seconds), 3) as double) as avg_clean_lap_seconds,
        cast(round(avg(fuel_corrected_lap_seconds), 3) as double) as avg_fuel_corrected_lap_seconds,
        cast(round(min(fuel_corrected_lap_seconds), 3) as double) as best_fuel_corrected_lap_seconds,
        case
            when count(*) >= 5
                then cast(round(regr_slope(fuel_corrected_lap_seconds, cast(tyre_age_lap as double)), 4) as double)
        end as deg_slope_s_per_lap,
        case
            when count(*) >= 6
                then cast(
                    round(
                        avg(fuel_corrected_lap_seconds) filter (where stint_clean_lap_seq_asc <= 3),
                        3
                    ) as double
                )
        end as early_stint_fc_lap_s,
        case
            when count(*) >= 6
                then cast(
                    round(
                        avg(fuel_corrected_lap_seconds) filter (where stint_clean_lap_seq_desc <= 3),
                        3
                    ) as double
                )
        end as late_stint_fc_lap_s,
        case
            when count(*) >= 4
                then cast(
                    round(
                        quantile_cont(fuel_corrected_lap_seconds, 0.75)
                        - quantile_cont(fuel_corrected_lap_seconds, 0.25),
                        3
                    ) as double
                )
        end as lap_time_iqr_seconds,
        cast(coalesce(sum(purple_mini_sectors), 0) as integer) as purple_mini_sector_count
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
        coalesce(cp.circuit_archetype, 'unknown') as circuit_archetype,
        sessions.season_year,
        sessions.session_date,
        drivers.team_name,
        drivers.team_colour_hex,
        stints.driver_number,
        drivers.driver_acronym,
        stints.stint_number,
        stints.compound,
        case stints.compound
            when 'HARD' then coalesce(cp.pirelli_hard_spec, 'HARD')
            when 'MEDIUM' then coalesce(cp.pirelli_medium_spec, 'MEDIUM')
            when 'SOFT' then coalesce(cp.pirelli_soft_spec, 'SOFT')
            else stints.compound
        end as pirelli_c_spec,
        stints.lap_start,
        stints.lap_end,
        stints.stint_laps,
        stints.tyre_age_at_start,
        stints.is_fresh_tyre,
        coalesce(metrics.clean_lap_count, 0) as clean_lap_count,
        metrics.avg_clean_lap_seconds,
        metrics.avg_fuel_corrected_lap_seconds,
        metrics.best_fuel_corrected_lap_seconds,
        metrics.deg_slope_s_per_lap,
        metrics.early_stint_fc_lap_s,
        metrics.late_stint_fc_lap_s,
        cast(
            round(metrics.late_stint_fc_lap_s - metrics.early_stint_fc_lap_s, 3)
            as double
        ) as stint_pace_dropoff_s,
        metrics.lap_time_iqr_seconds,
        coalesce(metrics.purple_mini_sector_count, 0) as purple_mini_sector_count,
        case
            when metrics.deg_slope_s_per_lap is null then 'insufficient_laps'
            when metrics.deg_slope_s_per_lap < 0.03 then 'low_deg'
            when metrics.deg_slope_s_per_lap < 0.08 then 'moderate_deg'
            else 'high_deg'
        end as deg_profile_tier
    from stints
    inner join drivers
        on stints.session_key = drivers.session_key
        and stints.driver_number = drivers.driver_number
    inner join sessions
        on stints.session_key = sessions.session_key
    inner join meetings
        on stints.meeting_key = meetings.meeting_key
    left join circuit_profiles as cp
        on sessions.circuit_short_name = cp.circuit_short_name
    left join stint_deg_metrics as metrics
        on stints.stint_id = metrics.stint_id
)

select * from final
