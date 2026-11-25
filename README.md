# f1-dbt

Learning modern **dbt v2 (Fusion engine)** with **DuckDB**, **dbt Semantic Models**, and **dbt Charts** using public Formula 1 race data from the [OpenF1 API](https://openf1.org/), focused on analyzing F1 racing teams (pit crew execution, tire strategy, driver lineups, and championship pace).

## Prerequisites

- **dbt v2** (`brew tap dbt-labs/dbt && brew install dbt-labs/dbt/dbt`)
- **DuckDB CLI** (`brew install duckdb`)
- **uv** (`https://docs.astral.sh/uv/`)
- **dbt Charts** (`uv tool install dbt-charts`)

## Quickstart

1. **Install Python ingestion dependencies**
   ```bash
   uv sync
   ```
2. **Ingest OpenF1 race data incrementally into local DuckDB (`data/f1.duckdb`)**
   ```bash
   # Load all completed 2025 + 2026 races (idempotent DELETE+INSERT by session_key;
   # skips already-loaded races and paces live API calls to respect OpenF1 rate limits)
   uv run python scripts/ingest_openf1.py --year 2025 2026 --limit 0 --refresh-metadata

   # Backfill a single race by session_key
   uv run python scripts/ingest_openf1.py --year 2026 --limit 0 --session-key 11420
   ```
3. **Run dbt v2 locally**
   ```bash
   dbt debug
   dbt source freshness
   dbt build --static-analysis strict --generate-info-schema
   dbt lint
   ```
4. **Backfill a single month via Microbatch**
   ```bash
   dbt run --select fct_race_laps --event-time-start 2025-04-01 --event-time-end 2025-05-01
   ```
5. **Launch interactive dbt Charts dashboards**
   ```bash
   dct validate --warehouse
   dct serve --port 8080
   # Open http://localhost:8080/f1_team_strategy/
   # Dark mode: http://localhost:8080/f1_team_strategy_dark/
   ```
6. **Launch Evidence.dev Per-Race Winner Reports**
   ```bash
   npm --prefix reports install
   npm --prefix reports run sources
   npm --prefix reports run dev
   # Open http://localhost:3000/races/las-vegas-2026
   ```

## What's Inside

- **Staging (`models/staging/openf1/`)**: 7 OpenF1 views with `data_tests`, `event_time` configs, and Fusion static SQL analysis + queryable Parquet column lineage (`target/info_schema/v1/`).
- **Intermediate (`models/intermediate/`)**: `int_team_pit_stops` and `int_stint_pace` protected by **enforced Model Contracts** and **native YAML Unit Tests**.
- **Marts (`models/marts/`)**: `dim_teams`, `fct_team_race_performance`, `metricflow_time_spine`, and microbatch incremental `fct_race_laps`, plus **model-embedded dbt v2 Semantic Models, 11 Metrics (simple, ratio, derived), and Saved Queries**.
- **Snapshots (`snapshots/snp_driver_team_rosters.yml`)**: YAML-defined Type-2 SCD snapshot tracking driver-to-team swaps.
- **dbt Charts (`charts/`)**: Declarative YAML dashboards (`f1_team_strategy.yml` + dark `neon` variant) wired into the dbt DAG via `dct exposures` (`models/dbt_charts/exposures.yml`).

## Workflow & CI/CD

- Every Pull Request to `main` runs [.github/workflows/ci.yml](.github/workflows/ci.yml): installs `dbt` v2 + `dbt-charts`, loads a cached 1-race OpenF1 sample into DuckDB, and runs `dbt debug`, `dbt parse`, `dbt source freshness`, `dbt build`, `dbt lint`, `dct validate --warehouse`, and `dct exposures --check`.
