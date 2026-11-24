"""Ingest public OpenF1 API data into a local DuckDB database.

Fetches meetings, sessions, drivers (with team metadata), tire stints, pit stops,
laps, and session results for Race sessions and loads them into the `raw_openf1`
schema of `data/f1.duckdb`. Responses are cached locally in `data/raw/` so repeated
runs are fast and respectful of OpenF1 rate limits.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import duckdb
import httpx

BASE_URL = "https://api.openf1.org/v1"
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"
RAW_CACHE_DIR = DATA_DIR / "raw"
DB_PATH = DATA_DIR / "f1.duckdb"

# OpenF1 free tier allows ~30 requests per minute (bursts of 3/sec).
REQUEST_DELAY_SECONDS = 0.75


def fetch_json(
    client: httpx.Client,
    endpoint: str,
    params: dict[str, Any],
    cache_path: Path,
    force_refresh: bool = False,
) -> list[dict[str, Any]]:
    """Fetch JSON list from OpenF1 with local file caching and 429 retry handling."""
    if cache_path.exists() and not force_refresh:
        return json.loads(cache_path.read_text(encoding="utf-8"))

    url = f"{BASE_URL}/{endpoint}"
    for attempt in range(1, 8):
        time.sleep(REQUEST_DELAY_SECONDS)
        resp = client.get(url, params=params, timeout=30.0)
        if resp.status_code == 200:
            data = resp.json()
            if not isinstance(data, list):
                data = []
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(data), encoding="utf-8")
            return data
        if resp.status_code == 404:
            # Endpoint or session has no data available
            return []
        if resp.status_code == 429:
            retry_after = resp.headers.get("Retry-After")
            wait = float(retry_after) if retry_after and retry_after.isdigit() else min(5.0 * attempt, 25.0)
            print(f"  Rate limited on {endpoint} ({params}); waiting {wait:.1f}s...")
            time.sleep(wait)
            continue
        resp.raise_for_status()

    raise RuntimeError(f"Failed to fetch {url} with params {params} after retries")


def write_ndjson(records: list[dict[str, Any]], path: Path) -> Path:
    """Write a list of JSON objects as newline-delimited JSON for DuckDB ingestion."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in records:
            fh.write(json.dumps(row) + "\n")
    return path


def load_into_duckdb(tables: dict[str, list[dict[str, Any]]], db_path: Path) -> None:
    """Load collected OpenF1 records into raw_openf1.* tables in DuckDB."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    staging_dir = DATA_DIR / "ndjson"
    staging_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(str(db_path))
    try:
        con.execute("CREATE SCHEMA IF NOT EXISTS raw_openf1;")
        for table_name, records in tables.items():
            if not records:
                print(f"  Skipping raw_openf1.{table_name} (0 records)")
                continue
            ndjson_path = write_ndjson(records, staging_dir / f"{table_name}.ndjson")
            con.execute(
                f"""
                CREATE OR REPLACE TABLE raw_openf1.{table_name} AS
                SELECT
                    *,
                    current_timestamp AS _ingested_at
                FROM read_json_auto('{ndjson_path.as_posix()}', format='newline_delimited');
                """
            )
            count = con.execute(f"SELECT count(*) FROM raw_openf1.{table_name}").fetchone()[0]
            print(f"  Loaded raw_openf1.{table_name}: {count:,} rows")
    finally:
        con.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest OpenF1 race data into DuckDB.")
    parser.add_argument(
        "--year",
        type=int,
        default=2025,
        help="F1 season year to ingest (default: 2025).",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=6,
        help="Number of Race sessions to ingest (0 = all races in the season; default: 6).",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Ignore local JSON cache and re-fetch from OpenF1 API.",
    )
    args = parser.parse_args()

    year = args.year
    year_cache = RAW_CACHE_DIR / str(year)

    print(f"Fetching OpenF1 {year} season metadata...")
    with httpx.Client(headers={"User-Agent": "f1-dbt-learning/0.1"}) as client:
        meetings = fetch_json(
            client,
            "meetings",
            {"year": year},
            year_cache / "meetings.json",
            force_refresh=args.refresh,
        )
        sessions = fetch_json(
            client,
            "sessions",
            {"year": year, "session_name": "Race"},
            year_cache / "race_sessions.json",
            force_refresh=args.refresh,
        )

        # Sort chronologically and optionally take the first N races
        sessions = sorted(sessions, key=lambda s: s.get("date_start") or "")
        if args.limit > 0:
            sessions = sessions[: args.limit]

        meeting_keys = {s["meeting_key"] for s in sessions if "meeting_key" in s}
        meetings = [m for m in meetings if m.get("meeting_key") in meeting_keys]

        print(f"Selected {len(sessions)} Race session(s) across {len(meetings)} meeting(s).")

        per_session_endpoints = ["drivers", "stints", "pit", "laps", "session_result"]
        collected: dict[str, list[dict[str, Any]]] = {
            "meetings": meetings,
            "sessions": sessions,
            **{ep: [] for ep in per_session_endpoints},
        }

        for idx, session in enumerate(sessions, start=1):
            session_key = session["session_key"]
            location = session.get("location") or session.get("country_name") or str(session_key)
            print(f"[{idx}/{len(sessions)}] Fetching {location} (session_key={session_key})...")
            for ep in per_session_endpoints:
                rows = fetch_json(
                    client,
                    ep,
                    {"session_key": session_key},
                    year_cache / f"session_{session_key}" / f"{ep}.json",
                    force_refresh=args.refresh,
                )
                collected[ep].extend(rows)

    print(f"\nLoading tables into {DB_PATH}...")
    load_into_duckdb(collected, DB_PATH)
    print("Done!")


if __name__ == "__main__":
    main()
