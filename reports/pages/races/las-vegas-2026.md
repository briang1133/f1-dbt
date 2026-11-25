---
title: 2026 Las Vegas Grand Prix — Winner Breakdown
---

```sql vegas_winner
select
    meeting_name,
    race_date,
    driver_full_name,
    driver_acronym,
    team_name,
    winning_margin_seconds,
    avg_clean_lap_seconds,
    avg_stop_duration_seconds,
    total_pit_lane_seconds,
    max_speed_trap_kph,
    tyre_strategy,
    winner_vs_p2_avg_lap_s,
    winner_vs_p2_s1_s,
    winner_vs_p2_s2_s,
    winner_vs_p2_s3_s,
    round(winner_vs_p2_s1_s + winner_vs_p2_s2_s, 3) as s1_s2_combined_delta_s,
    winner_vs_p2_pit_lane_s
from f1_duckdb.race_breakdown
where session_key = 11420 and is_winner = true
```

```sql vegas_p2
select
    driver_full_name,
    team_name,
    avg_stop_duration_seconds,
    total_pit_lane_seconds,
    max_speed_trap_kph,
    avg_clean_lap_seconds
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position = 2
```

```sql vegas_p3
select
    driver_full_name,
    team_name,
    gap_to_leader_seconds,
    avg_clean_lap_seconds,
    avg_stop_duration_seconds,
    total_pit_lane_seconds,
    delta_vs_winner_pit_lane_s,
    max_speed_trap_kph
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position = 3
```

**Date:** <Value data={vegas_winner} column=race_date /> · **Circuit:** Las Vegas Strip Circuit · **Winner:** **<Value data={vegas_winner} column=driver_full_name />** (<Value data={vegas_winner} column=team_name />)

<Grid cols=4>
  <BigValue data={vegas_winner} value=winning_margin_seconds fmt="0.000's'" title="Winning Margin vs P2" />
  <BigValue data={vegas_winner} value=winner_vs_p2_pit_lane_s fmt="+0.00's';-0.00's'" title="Pit Lane Time vs P2" />
  <BigValue data={vegas_winner} value=s1_s2_combined_delta_s fmt="+0.000's';-0.000's'" title="S1 + S2 Edge vs P2 / Lap" />
  <BigValue data={vegas_winner} value=winner_vs_p2_s3_s fmt="+0.000's';-0.000's'" title="S3 Trade-Off vs P2 / Lap" />
</Grid>

## Executive Summary: Three Reasons Max Verstappen Won Las Vegas 2026

On paper, this was a razor-thin **<Value data={vegas_winner} column=winning_margin_seconds fmt="0.000" />s** thriller between **<Value data={vegas_winner} column=driver_full_name />** and **<Value data={vegas_p2} column=driver_full_name />**—with **<Value data={vegas_p3} column=driver_full_name />** actually running a *faster* clean-air lap average (<Value data={vegas_p3} column=avg_clean_lap_seconds fmt="0.000" />s vs. Verstappen's <Value data={vegas_winner} column=avg_clean_lap_seconds fmt="0.000" />s). Three decisive factors sealed the win:

1. **Pit Crew Execution Won the Race in the Pit Lane:** All three podium finishers ran the exact same **<Value data={vegas_winner} column=tyre_strategy />** one-stop strategy. Red Bull delivered an **elite <Value data={vegas_winner} column=avg_stop_duration_seconds fmt="0.00" />s stationary stop** (<Value data={vegas_winner} column=total_pit_lane_seconds fmt="0.00" />s total pit lane loss), while McLaren struggled badly—Norris took **<Value data={vegas_p2} column=avg_stop_duration_seconds fmt="0.00" />s** stationary (<Value data={vegas_p2} column=total_pit_lane_seconds fmt="0.00" />s total, losing **3.59s** to Verstappen in the pits) and Piastri lost **+<Value data={vegas_p3} column=delta_vs_winner_pit_lane_s fmt="0.00" />s** in the pit lane despite finishing only <Value data={vegas_p3} column=gap_to_leader_seconds fmt="0.000" />s behind.
2. **Higher-Downforce Setup Dominated Sectors 1 & 2:** Red Bull sacrificed top-end speed on the Strip (**<Value data={vegas_winner} column=max_speed_trap_kph fmt="0" /> kph** vs. McLaren's **<Value data={vegas_p2} column=max_speed_trap_kph fmt="0" />–<Value data={vegas_p3} column=max_speed_trap_kph fmt="0" /> kph**), giving up **+<Value data={vegas_winner} column=winner_vs_p2_s3_s fmt="0.000" />s/lap** in Sector 3—but gained **<Value data={vegas_winner} column=s1_s2_combined_delta_s fmt="0.000" />s/lap** through the technical braking and cornering zones of Sectors 1 and 2.
3. **Clean-Air Track Position & Tire Control:** Leaving the pit lane ahead after Lap 19 let Verstappen manage tire temperatures on his 31-lap Medium stint while McLaren burned battery and tire life trying to close the gap in dirty air.

---

## 1. Where the Race Was Won: Pit Lane Execution

```sql vegas_pit_comparison
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    team_name,
    finish_position,
    avg_stop_duration_seconds as stationary_stop_s,
    total_pit_lane_seconds as total_pit_lane_s,
    delta_vs_winner_pit_lane_s as time_lost_vs_winner_s
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position <= 6
order by finish_position
```

<Grid cols=2>
  <BarChart
      data={vegas_pit_comparison}
      x=driver
      y=stationary_stop_s
      title="Stationary Pit Crew Stop Time (seconds)"
      subtitle="Lower is faster — Red Bull's 2.40s stop vs McLaren's 6.30s / 4.50s"
      yAxisTitle="Seconds"
      labels=true
      sort=false
  />
  <BarChart
      data={vegas_pit_comparison}
      x=driver
      y=time_lost_vs_winner_s
      title="Total Pit Lane Time Lost vs. Verstappen (seconds)"
      subtitle="Both McLarens lost 3.59s to 6.26s in the pit lane alone"
      yAxisTitle="Delta vs VER (s)"
      labels=true
      sort=false
  />
</Grid>

---

## 2. Setup Divergence: High Downforce (S1 & S2) vs. Strip Speed (S3)

Positive values mean the rival was **slower** than Verstappen in that sector; negative values mean the rival was **faster** than Verstappen.

```sql vegas_sector_deltas
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 1' as sector,
    delta_vs_winner_s1_s as delta_vs_ver_s
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position between 2 and 5
union all
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 2' as sector,
    delta_vs_winner_s2_s as delta_vs_ver_s
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position between 2 and 5
union all
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    'Sector 3 (Strip)' as sector,
    delta_vs_winner_s3_s as delta_vs_ver_s
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position between 2 and 5
```

```sql vegas_speed_trap
select
    driver_acronym || ' (P' || cast(finish_position as varchar) || ')' as driver,
    max_speed_trap_kph as top_speed_kph,
    finish_position
from f1_duckdb.race_breakdown
where session_key = 11420 and finish_position <= 6
order by finish_position
```

<Grid cols=2>
  <BarChart
      data={vegas_sector_deltas}
      x=sector
      y=delta_vs_ver_s
      series=driver
      type=grouped
      title="Rival Sector Pace Delta vs. Verstappen (s/lap)"
      subtitle="Rivals lost 0.4–0.9s/lap in S1 & S2, then clawed back ~1.0s/lap on the Strip (S3)"
      yAxisTitle="Seconds vs VER (+ = slower)"
      sort=false
  />
  <BarChart
      data={vegas_speed_trap}
      x=driver
      y=top_speed_kph
      title="Peak Speed Trap (kph) — Top 6"
      subtitle="Red Bull ran ~20 kph lower top speed to gain braking & cornering grip"
      yAxisTitle="kph"
      yMin=290
      labels=true
      sort=false
  />
</Grid>

---

## 3. Lap-by-Lap Pace Battle: Verstappen vs. Norris vs. Piastri

```sql vegas_lap_battle
select
    lap_number,
    driver_acronym,
    round(lap_duration_seconds, 3) as lap_time_s
from f1_duckdb.race_laps
where
    session_key = 11420
    and driver_acronym in ('VER', 'NOR', 'PIA')
    and lap_number > 1
    and not is_pit_out_lap
    and lap_duration_seconds < 106
order by lap_number, driver_acronym
```

<LineChart
    data={vegas_lap_battle}
    x=lap_number
    y=lap_time_s
    series=driver_acronym
    title="Clean Racing Lap Times Across All 50 Laps (VER vs. NOR vs. PIA)"
    subtitle="Excludes Lap 1, pit-out laps, and Safety Car / VSC laps (>106s)"
    xAxisTitle="Lap Number"
    yAxisTitle="Lap Time (seconds)"
    yMin=95
    yMax=105
/>

---

## 4. Tire Stint Breakdown (Top 6 Finishers)

```sql vegas_stints
select
    b.finish_position as pos,
    s.driver_acronym as driver,
    s.team_name as team,
    s.stint_number as stint,
    s.compound,
    s.lap_start,
    s.lap_end,
    s.stint_laps as laps,
    s.avg_clean_lap_seconds as avg_clean_lap_s,
    s.fastest_stint_lap_seconds as best_lap_s,
    s.max_speed_trap_kph as top_kph
from f1_duckdb.stint_pace s
inner join f1_duckdb.race_breakdown b
    on s.session_key = b.session_key
    and s.driver_number = b.driver_number
where s.session_key = 11420 and b.finish_position <= 6
order by b.finish_position, s.stint_number
```

<DataTable data={vegas_stints} rows=15>
    <Column id=pos title="Pos" fmt="0" />
    <Column id=driver title="Driver" />
    <Column id=team title="Team" />
    <Column id=stint title="Stint" fmt="0" />
    <Column id=compound title="Compound" />
    <Column id=lap_start title="Start Lap" fmt="0" />
    <Column id=lap_end title="End Lap" fmt="0" />
    <Column id=laps title="Laps" fmt="0" />
    <Column id=avg_clean_lap_s title="Avg Clean Lap (s)" fmt="0.000" />
    <Column id=best_lap_s title="Best Lap (s)" fmt="0.000" />
    <Column id=top_kph title="Top kph" fmt="0" />
</DataTable>

---

## 5. Year-over-Year Contrast: Las Vegas 2025 vs. 2026

```sql vegas_yoy
select
    season_year,
    driver_full_name as winner,
    team_name as team,
    winning_margin_seconds as margin_s,
    avg_clean_lap_seconds as avg_lap_s,
    avg_stop_duration_seconds as stop_s,
    max_speed_trap_kph as top_kph,
    tyre_strategy
from f1_duckdb.race_breakdown
where circuit_short_name = 'Las Vegas' and is_winner = true
order by season_year desc
```

<DataTable data={vegas_yoy}>
    <Column id=season_year title="Season" fmt="0" />
    <Column id=winner title="Winner" />
    <Column id=team title="Team" />
    <Column id=margin_s title="Margin vs P2 (s)" fmt="0.000" />
    <Column id=avg_lap_s title="Avg Clean Lap (s)" fmt="0.000" />
    <Column id=stop_s title="Stationary Stop (s)" fmt="0.00" />
    <Column id=top_kph title="Top Speed (kph)" fmt="0" />
    <Column id=tyre_strategy title="Strategy" />
</DataTable>

---

## 6. Full 2026 Las Vegas Classification & Winner Deltas

```sql vegas_full_grid
select
    finish_position as pos,
    driver_acronym as driver,
    driver_full_name as name,
    team_name as team,
    gap_to_leader_seconds as gap_s,
    avg_clean_lap_seconds as avg_lap_s,
    delta_vs_winner_avg_lap_s as lap_delta_s,
    avg_stop_duration_seconds as stop_s,
    delta_vs_winner_pit_lane_s as pit_delta_s,
    max_speed_trap_kph as top_kph,
    tyre_strategy
from f1_duckdb.race_breakdown
where session_key = 11420
order by finish_position asc nulls last
```

<DataTable data={vegas_full_grid} search=true rows=22>
    <Column id=pos title="Pos" fmt="0" />
    <Column id=driver title="Code" />
    <Column id=name title="Driver" />
    <Column id=team title="Team" />
    <Column id=gap_s title="Gap (s)" fmt="0.000" />
    <Column id=avg_lap_s title="Avg Lap (s)" fmt="0.000" />
    <Column id=lap_delta_s title="Lap vs VER (s)" fmt="+0.000;-0.000;0.000" />
    <Column id=stop_s title="Stop (s)" fmt="0.00" />
    <Column id=pit_delta_s title="Pit vs VER (s)" fmt="+0.00;-0.00;0.00" />
    <Column id=top_kph title="Top kph" fmt="0" />
    <Column id=tyre_strategy title="Strategy" />
</DataTable>

[← Back to All Race Reports](../)
