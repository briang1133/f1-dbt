---
title: Race Winner Breakdown
---

```sql race_winner
select
    session_key,
    season_year,
    meeting_name,
    circuit_short_name,
    country_name,
    race_date,
    driver_full_name,
    driver_acronym,
    team_name,
    winning_margin_seconds,
    avg_clean_lap_seconds,
    fastest_lap_seconds,
    avg_stop_duration_seconds,
    total_pit_lane_seconds,
    max_speed_trap_kph,
    tyre_strategy,
    winner_vs_p2_avg_lap_s,
    winner_vs_p2_s1_s,
    winner_vs_p2_s2_s,
    winner_vs_p2_s3_s,
    winner_vs_p2_pit_lane_s,
    case
        when winner_vs_p2_pit_lane_s <= -2.0 and coalesce(winner_vs_p2_avg_lap_s, 0) > -0.1
            then 'Pit Lane & Strategy Execution'
        when winner_vs_p2_avg_lap_s <= -0.25
            then 'Dominant Clean-Air Race Pace'
        when abs(coalesce(winner_vs_p2_s1_s, 0)) >= 0.25
            or abs(coalesce(winner_vs_p2_s2_s, 0)) >= 0.25
            or abs(coalesce(winner_vs_p2_s3_s, 0)) >= 0.25
            then 'Sector-Specific Setup Advantage'
        else 'Track Position & Consistent Execution'
    end as primary_winning_factor
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and is_winner = true
```

```sql race_p2
select
    driver_full_name,
    driver_acronym,
    team_name,
    avg_clean_lap_seconds,
    avg_stop_duration_seconds,
    total_pit_lane_seconds,
    tyre_strategy
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and finish_position = 2
```

# <Value data={race_winner} column=season_year fmt="0" /> <Value data={race_winner} column=meeting_name />

**Date:** <Value data={race_winner} column=race_date /> · **Circuit:** <Value data={race_winner} column=circuit_short_name /> (<Value data={race_winner} column=country_name />) · **Primary Winning Factor:** **<Value data={race_winner} column=primary_winning_factor />**

<Grid cols=4>
  <BigValue data={race_winner} value=driver_full_name title="Race Winner" />
  <BigValue data={race_winner} value=winning_margin_seconds fmt="0.000's'" title="Winning Margin vs P2" />
  <BigValue data={race_winner} value=winner_vs_p2_avg_lap_s fmt="+0.000's';-0.000's'" title="Clean Lap Delta vs P2" />
  <BigValue data={race_winner} value=winner_vs_p2_pit_lane_s fmt="+0.00's';-0.00's'" title="Pit Lane Delta vs P2" />
</Grid>

**<Value data={race_winner} column=driver_full_name />** (<Value data={race_winner} column=team_name />) won on a **<Value data={race_winner} column=tyre_strategy />** strategy, finishing **<Value data={race_winner} column=winning_margin_seconds fmt="0.000" />s** ahead of **<Value data={race_p2} column=driver_full_name />** (<Value data={race_p2} column=team_name />, **<Value data={race_p2} column=tyre_strategy />**).

---

## 1. Sector-by-Sector Advantage vs. Top 5 Rivals

```sql sector_deltas
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 1' as sector,
    delta_vs_winner_s1_s as delta_vs_winner_s
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and finish_position between 2 and 5
union all
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 2' as sector,
    delta_vs_winner_s2_s as delta_vs_winner_s
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and finish_position between 2 and 5
union all
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 3' as sector,
    delta_vs_winner_s3_s as delta_vs_winner_s
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and finish_position between 2 and 5
```

```sql top6_pits
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    avg_stop_duration_seconds as stationary_stop_s,
    total_pit_lane_seconds as total_pit_lane_s,
    finish_position
from f1_duckdb.race_breakdown
where session_key = ${params.session_key} and finish_position <= 6
order by finish_position
```

<Grid cols=2>
  <BarChart
      data={sector_deltas}
      x=sector
      y=delta_vs_winner_s
      series=driver
      type=grouped
      title="Rival Sector Delta vs. Winner (s/lap)"
      subtitle="Positive = slower than the winner"
      yAxisTitle="Delta vs Winner (s)"
      sort=false
  />
  <BarChart
      data={top6_pits}
      x=driver
      y=total_pit_lane_s
      title="Total Pit Lane Time — Top 6 (seconds)"
      subtitle="Lower means less race time spent in the pit lane"
      yAxisTitle="Seconds"
      labels=true
      sort=false
  />
</Grid>

---

## 2. Lap-by-Lap Pace Comparison (Podium Finishers)

```sql podium_laps
with podium as (
    select driver_number
    from f1_duckdb.race_breakdown
    where session_key = ${params.session_key} and finish_position <= 3
),
bench as (
    select min(lap_duration_seconds) as fastest_lap
    from f1_duckdb.race_laps
    where session_key = ${params.session_key} and lap_number > 1 and not is_pit_out_lap
)
select
    l.lap_number,
    l.driver_acronym,
    round(l.lap_duration_seconds, 3) as lap_time_s
from f1_duckdb.race_laps l
inner join podium p on l.driver_number = p.driver_number
cross join bench b
where
    l.session_key = ${params.session_key}
    and l.lap_number > 1
    and not l.is_pit_out_lap
    and l.lap_duration_seconds <= b.fastest_lap * 1.12
order by l.lap_number, l.driver_acronym
```

<LineChart
    data={podium_laps}
    x=lap_number
    y=lap_time_s
    series=driver_acronym
    title="Clean-Air Racing Lap Times (P1 vs. P2 vs. P3)"
    subtitle="Excludes Lap 1, pit-out laps, and Safety Car / VSC outliers (>12% off fastest lap)"
    xAxisTitle="Lap Number"
    yAxisTitle="Lap Time (seconds)"
/>

---

## 3. Full Race Classification & Winner Deltas

```sql race_grid
select
    finish_position as pos,
    driver_acronym as code,
    driver_full_name as driver,
    team_name as team,
    gap_to_leader_seconds as gap_s,
    avg_clean_lap_seconds as avg_lap_s,
    delta_vs_winner_avg_lap_s as lap_delta_s,
    avg_stop_duration_seconds as stop_s,
    delta_vs_winner_pit_lane_s as pit_delta_s,
    max_speed_trap_kph as top_kph,
    tyre_strategy
from f1_duckdb.race_breakdown
where session_key = ${params.session_key}
order by finish_position asc nulls last
```

<DataTable data={race_grid} search=true rows=22>
    <Column id=pos title="Pos" fmt="0" />
    <Column id=code title="Code" />
    <Column id=driver title="Driver" />
    <Column id=team title="Team" />
    <Column id=gap_s title="Gap (s)" fmt="0.000" />
    <Column id=avg_lap_s title="Avg Lap (s)" fmt="0.000" />
    <Column id=lap_delta_s title="Lap vs P1 (s)" fmt="+0.000;-0.000;0.000" />
    <Column id=stop_s title="Stop (s)" fmt="0.00" />
    <Column id=pit_delta_s title="Pit vs P1 (s)" fmt="+0.00;-0.00;0.00" />
    <Column id=top_kph title="Top kph" fmt="0" />
    <Column id=tyre_strategy title="Strategy" />
</DataTable>

[← Back to All Race Reports](/)
