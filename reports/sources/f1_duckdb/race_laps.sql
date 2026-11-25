select
    session_key,
    season_year,
    circuit_short_name,
    race_date,
    driver_number,
    driver_acronym,
    team_name,
    lap_number,
    stint_number,
    compound,
    lap_duration_seconds,
    sector_1_seconds,
    sector_2_seconds,
    sector_3_seconds,
    speed_trap_kph,
    is_pit_out_lap
from analytics.fct_race_laps
where lap_duration_seconds is not null
order by session_key, driver_number, lap_number
