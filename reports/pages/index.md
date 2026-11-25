---
title: F1 Race Winner Reports
---

Data-driven post-race breakdowns built with **dbt v2**, **DuckDB / MotherDuck**, and **Evidence.dev** across all **45 completed Grands Prix (2025–2026)**. Every race report decomposes *why* the winner took P1: clean-air pace, sector-by-sector setup edge, pit crew execution, and tire strategy.

```sql featured_vegas
select
    session_key,
    meeting_name,
    race_date,
    driver_full_name,
    team_name,
    winning_margin_seconds,
    winner_vs_p2_pit_lane_s,
    round(winner_vs_p2_s1_s + winner_vs_p2_s2_s, 3) as s1_s2_advantage_s,
    tyre_strategy
from f1_duckdb.race_breakdown
where session_key = 11420 and is_winner = true
```

## Featured Report: 2026 Las Vegas Grand Prix

<Grid cols=4>
  <BigValue data={featured_vegas} value=driver_full_name title="2026 Las Vegas Winner" />
  <BigValue data={featured_vegas} value=winning_margin_seconds fmt="0.000's'" title="Winning Margin vs P2" />
  <BigValue data={featured_vegas} value=winner_vs_p2_pit_lane_s fmt="+0.00's';-0.00's'" title="Pit Lane Delta vs P2" />
  <BigValue data={featured_vegas} value=s1_s2_advantage_s fmt="+0.000's';-0.000's'" title="S1 + S2 Edge vs P2 / Lap" />
</Grid>

👉 **[Read the full 2026 Las Vegas Race Winner Breakdown →](/races/las-vegas-2026)** · **[Compare with 2025 Las Vegas GP →](/races/9858)**

---

## Explore Every Grand Prix (2025–2026)

```sql all_races
select
    '/races/' || cast(session_key as varchar) as report_url,
    season_year,
    race_date,
    meeting_name,
    circuit_short_name,
    driver_full_name as winner,
    team_name as team,
    winning_margin_seconds as margin_s,
    winner_vs_p2_avg_lap_s as lap_delta_vs_p2_s,
    winner_vs_p2_pit_lane_s as pit_delta_vs_p2_s,
    tyre_strategy
from f1_duckdb.race_breakdown
where is_winner = true
order by race_date desc
```

Search by year (`2026`, `2025`), circuit, driver, or team—and click any Grand Prix link to open its full **Race Winner Breakdown** report:

<DataTable
    data={all_races}
    search=true
    rows=50
>
    <Column id=season_year title="Year" fmt="0" />
    <Column id=race_date title="Date" />
    <Column id=report_url title="Grand Prix" contentType=link linkLabel=meeting_name />
    <Column id=circuit_short_name title="Circuit" />
    <Column id=winner title="Winner" />
    <Column id=team title="Team" />
    <Column id=margin_s title="Margin (s)" fmt="0.000" />
    <Column id=lap_delta_vs_p2_s title="Lap vs P2 (s)" fmt="+0.000;-0.000;0.000" />
    <Column id=pit_delta_vs_p2_s title="Pit vs P2 (s)" fmt="+0.00;-0.00;0.00" />
    <Column id=tyre_strategy title="Winning Strategy" />
</DataTable>
