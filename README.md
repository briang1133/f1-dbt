# f1-dbt

Learning modern **dbt v2 (Fusion engine)** with **DuckDB** using public Formula 1 race data from the [OpenF1 API](https://openf1.org/), focused on analyzing F1 racing teams (pit crew execution, tire strategy, driver lineups, and pace).

## Prerequisites

- **dbt v2** (`brew tap dbt-labs/dbt && brew install dbt-labs/dbt/dbt`)
- **DuckDB CLI** (`brew install duckdb`)
- **uv** (`https://docs.astral.sh/uv/`)

## Quickstart

1. **Install Python ingestion dependencies**
   ```bash
   uv sync
   ```
2. **Ingest OpenF1 race data into local DuckDB (`data/f1.duckdb`)**
   ```bash
   # Load first 6 races of 2025 (cached in data/raw/ so re-runs are instant)
   uv run python scripts/ingest_openf1.py --year 2025 --limit 6

   # Or load the full season
   uv run python scripts/ingest_openf1.py --year 2025 --limit 0
   ```
3. **Run dbt v2 locally**
   ```bash
   dbt debug
   dbt source freshness
   dbt build
   dbt lint
   ```

## Workflow & CI/CD

- Local data (`data/`), build artifacts (`target/`), and `.venv/` are gitignored.
- Every Pull Request to `main` runs [.github/workflows/ci.yml](.github/workflows/ci.yml): installs `dbt` v2, loads a cached 1-race OpenF1 sample into DuckDB, and runs `dbt debug`, `dbt parse`, `dbt source freshness`, `dbt build`, and `dbt lint` against the `ci` target.
