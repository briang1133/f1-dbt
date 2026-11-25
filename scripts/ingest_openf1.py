"""Ingest public OpenF1 API data into a local DuckDB database (incremental ELT).

Uses an idempotent partitioned `DELETE + INSERT BY NAME` pattern keyed by
`session_key` (and `meeting_key` for `meetings`) inside atomic transactions:
  - Already-loaded completed sessions in `raw_openf1.sessions` are skipped
    automatically, preserving original `_ingested_at` timestamps on past races.
  - Individual sessions can be cleanly backfilled via `--session-key <id>`.
  - New JSON columns introduced in newer seasons are evolved automatically via
    `ALTER TABLE ... ADD COLUMN`.
  - API responses are cached locally in `data/raw/` and paced at >=2.25s between
    live requests to stay safely under OpenF1's ~30 req/min free-tier limit.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time
from typing import Any

import duckdb
import httpx

BASE_URL = "https://api.openf1.org/v1"
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"
RAW_CACHE_DIR = DATA_DIR / "raw"
DEFAULT_DB_PATH = DATA_DIR / "f1.duckdb"

# OpenF1 free tier allows ~30 requests/minute. Pacing uncached requests at 2.25s
# keeps sustained throughput <= ~26.6 req/min so we stay well below the cap.
MIN_REQUEST_INTERVAL_SECONDS = 2.25
_last_request_monotonic: float = 0.0

PARTITION_KEYS: dict[str, str] = {
    "meetings": "meeting_key",
    "sessions": "session_key",
    "drivers": "session_key",
    "stints": "session_key",
    "pit": "session_key",
    "laps": "session_key",
    "session_result": "session_key",
}


def _pace_request() -> None:
    """Sleep just enough so consecutive live API requests respect OpenF1 limits."""
    global _last_request_monotonic
    now = time.monotonic()
    elapsed = now - _last_request_monotonic
    if _last_request_monotonic > 0 and elapsed < MIN_REQUEST_INTERVAL_SECONDS:
        time.sleep(MIN_REQUEST_INTERVAL_SECONDS - elapsed)
    _last_request_monotonic = time.monotonic()


def fetch_json(
    client: httpx.Client,
    endpoint: str,
    params: dict[str, Any],
    cache_path: Path,
    force_refresh: bool = False,
) -> list[dict[str, Any]]:
    """Fetch JSON list from OpenF1 with local file caching and 429/5xx retry handling."""
    if cache_path.exists() and not force_refresh:
        return json.loads(cache_path.read_text(encoding="utf-8"))

    url = f"{BASE_URL}/{endpoint}"
    for attempt in range(1, 8):
        _pace_request()
        try:
            resp = client.get(url, params=params, timeout=45.0)
        except httpx.HTTPError as exc:
            wait = min(5.0 * attempt, 30.0)
            print(f"  Network error on {endpoint} ({params}): {exc}; retrying in {wait:.1f}s...", flush=True)
            time.sleep(wait)
            continue

        if resp.status_code == 200:
            data = resp.json()
            if not isinstance(data, list):
                data = []
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(data), encoding="utf-8")
            return data
        if resp.status_code == 404:
            return []
        if resp.status_code == 429:
            retry_after = resp.headers.get("Retry-After")
            wait = float(retry_after) if retry_after and retry_after.isdigit() else min(10.0 * attempt, 60.0)
            print(f"  Rate limited (429) on {endpoint} ({params}); waiting {wait:.1f}s...", flush=True)
            time.sleep(wait)
            continue
        if resp.status_code >= 500:
            wait = min(5.0 * attempt, 30.0)
            print(f"  Server error ({resp.status_code}) on {endpoint}; waiting {wait:.1f}s...", flush=True)
            time.sleep(wait)
            continue
        resp.raise_for_status()

    raise RuntimeError(f"Failed to fetch {url} with params {params} after retries")


def _is_completed_session(session: dict[str, Any], now_utc: datetime) -> bool:
    """Return True if the session has already ended and was not cancelled."""
    if session.get("is_cancelled"):
        return False
    date_str = session.get("date_end") or session.get("date_start")
    if not date_str:
        return False
    try:
        dt = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt < now_utc
    except ValueError:
        return True


def _is_motherduck(db_path: str) -> bool:
    return db_path.startswith("md:")


def _connect_duckdb(db_path: str) -> duckdb.DuckDBPyConnection:
    """Open local DuckDB (v1.4.0 storage compat) or MotherDuck cloud database."""
    if _is_motherduck(db_path):
        if not os.environ.get("MOTHERDUCK_TOKEN"):
            raise RuntimeError(
                "MOTHERDUCK_TOKEN environment variable is required to connect to MotherDuck (`md:...`)."
            )
        # Ensure the target MotherDuck database exists on first run before USEing it.
        db_name = db_path[len("md:") :].split("?", 1)[0].strip()
        if db_name:
            con = duckdb.connect("md:")
            con.execute(f'CREATE DATABASE IF NOT EXISTS "{db_name}";')
            con.execute(f'USE "{db_name}";')
            return con
        return duckdb.connect(db_path)

    local_path = Path(db_path)
    local_path.parent.mkdir(parents=True, exist_ok=True)
    return duckdb.connect(
        str(local_path),
        config={"storage_compatibility_version": "v1.4.0"},
    )


def get_loaded_session_keys(db_path: str) -> set[int]:
    """Return session_key values already loaded in raw_openf1.sessions."""
    if not _is_motherduck(db_path) and not Path(db_path).exists():
        return set()
    con = _connect_duckdb(db_path)
    try:
        exists = con.execute(
            """
            SELECT count(*)
            FROM information_schema.tables
            WHERE
                table_catalog = current_database()
                AND table_schema = 'raw_openf1'
                AND table_name = 'sessions'
            """
        ).fetchone()[0]
        if not exists:
            return set()
        rows = con.execute("SELECT DISTINCT session_key FROM raw_openf1.sessions").fetchall()
        return {int(r[0]) for r in rows if r[0] is not None}
    finally:
        con.close()


def write_ndjson(records: list[dict[str, Any]], path: Path) -> Path:
    """Write a list of JSON objects as newline-delimited JSON for DuckDB ingestion."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in records:
            fh.write(json.dumps(row) + "\n")
    return path


def _normalize_duckdb_type(col_type: str) -> str:
    """Replace DuckDB's pseudo-type \"NULL\" with VARCHAR for safe DDL."""
    cleaned = col_type.strip().strip('"').upper()
    return "VARCHAR" if cleaned in ("NULL", "SQLNULL") else col_type


def _evolve_target_schema(con: duckdb.DuckDBPyConnection, table_name: str) -> None:
    """Add any new columns from temp table `_incoming` to `raw_openf1.<table_name>`."""
    existing_cols = {
        row[0]: row[1]
        for row in con.execute(
            """
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE
                table_catalog = current_database()
                AND table_schema = 'raw_openf1'
                AND table_name = ?
            """,
            [table_name],
        ).fetchall()
    }
    incoming_cols = [
        (row[0], row[1])
        for row in con.execute("DESCRIBE _incoming").fetchall()
    ]

    for col_name, col_type in incoming_cols:
        safe_type = _normalize_duckdb_type(col_type)
        if col_name not in existing_cols:
            con.execute(f'ALTER TABLE raw_openf1.{table_name} ADD COLUMN "{col_name}" {safe_type};')
        elif existing_cols[col_name].strip().strip('"').upper() in ("NULL", "SQLNULL") and safe_type != "VARCHAR":
            con.execute(f'ALTER TABLE raw_openf1.{table_name} ALTER COLUMN "{col_name}" TYPE {safe_type};')


def load_into_duckdb(
    tables: dict[str, list[dict[str, Any]]],
    db_path: str,
    full_refresh: bool = False,
) -> None:
    """Incrementally load OpenF1 batches into raw_openf1.* via DELETE + INSERT BY NAME."""
    staging_dir = DATA_DIR / "ndjson"
    staging_dir.mkdir(parents=True, exist_ok=True)

    con = _connect_duckdb(db_path)
    try:
        con.execute("CREATE SCHEMA IF NOT EXISTS raw_openf1;")
        for table_name, records in tables.items():
            if not records:
                print(f"  Skipping raw_openf1.{table_name} (0 new records)", flush=True)
                continue

            partition_key = PARTITION_KEYS[table_name]
            ndjson_path = write_ndjson(records, staging_dir / f"{table_name}.ndjson")

            con.execute(
                f"""
                CREATE OR REPLACE TEMP TABLE _incoming AS
                SELECT
                    *,
                    current_timestamp AS _ingested_at
                FROM read_json_auto(
                    '{ndjson_path.as_posix()}',
                    format='newline_delimited',
                    union_by_name=true
                );
                """
            )

            table_exists = con.execute(
                """
                SELECT count(*)
                FROM information_schema.tables
                WHERE
                    table_catalog = current_database()
                    AND table_schema = 'raw_openf1'
                    AND table_name = ?
                """,
                [table_name],
            ).fetchone()[0] > 0

            if full_refresh or not table_exists:
                # Cast any all-null columns to VARCHAR on initial creation so future
                # non-null batches never clash with DuckDB's "NULL" column type.
                select_exprs = []
                for col_name, col_type, *_ in con.execute("DESCRIBE _incoming").fetchall():
                    if col_type.strip().strip('"').upper() in ("NULL", "SQLNULL"):
                        select_exprs.append(f'CAST("{col_name}" AS VARCHAR) AS "{col_name}"')
                    else:
                        select_exprs.append(f'"{col_name}"')
                con.execute(
                    f"""
                    CREATE OR REPLACE TABLE raw_openf1.{table_name} AS
                    SELECT {", ".join(select_exprs)}
                    FROM _incoming;
                    """
                )
                mode = "created" if not table_exists else "full-refreshed"
            else:
                _evolve_target_schema(con, table_name)
                con.execute("BEGIN TRANSACTION;")
                try:
                    con.execute(
                        f"""
                        DELETE FROM raw_openf1.{table_name}
                        WHERE {partition_key} IN (
                            SELECT DISTINCT {partition_key} FROM _incoming
                        );
                        """
                    )
                    con.execute(
                        f"""
                        INSERT INTO raw_openf1.{table_name} BY NAME
                        SELECT * FROM _incoming;
                        """
                    )
                    con.execute("COMMIT;")
                except Exception:
                    con.execute("ROLLBACK;")
                    raise
                mode = "upserted"

            batch_count = con.execute("SELECT count(*) FROM _incoming").fetchone()[0]
            total_count = con.execute(f"SELECT count(*) FROM raw_openf1.{table_name}").fetchone()[0]
            print(
                f"  {mode.capitalize()} raw_openf1.{table_name}: {batch_count:,} batch rows ({total_count:,} total)",
                flush=True,
            )
    finally:
        con.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Incrementally ingest OpenF1 race data into DuckDB.")
    parser.add_argument(
        "--year",
        type=int,
        nargs="+",
        default=[2025],
        help="One or more F1 season years to ingest (default: 2025). Example: --year 2025 2026",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=6,
        help="Max Race sessions per year to consider (0 = all completed races; default: 6).",
    )
    parser.add_argument(
        "--session-key",
        type=int,
        nargs="+",
        default=None,
        help="Optional explicit session_key(s) to backfill (deletes & re-inserts only those races).",
    )
    parser.add_argument(
        "--db-path",
        type=str,
        default=str(DEFAULT_DB_PATH),
        help=f"Target DuckDB file path or MotherDuck URI (e.g. md:f1_prod; default: {DEFAULT_DB_PATH}).",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Re-fetch from OpenF1 API ignoring local JSON cache and upsert selected sessions.",
    )
    parser.add_argument(
        "--refresh-metadata",
        action="store_true",
        help="Re-fetch season meetings/sessions index while keeping cached per-session files.",
    )
    parser.add_argument(
        "--full-refresh",
        action="store_true",
        help="Drop and recreate raw_openf1.* tables from scratch for the selected seasons.",
    )
    args = parser.parse_args()

    now_utc = datetime.now(timezone.utc)
    explicit_keys = set(args.session_key) if args.session_key else None
    loaded_keys = set() if (args.full_refresh or args.refresh) else get_loaded_session_keys(args.db_path)

    per_session_endpoints = ["drivers", "stints", "pit", "laps", "session_result"]
    collected: dict[str, list[dict[str, Any]]] = {
        "meetings": [],
        "sessions": [],
        **{ep: [] for ep in per_session_endpoints},
    }

    sessions_to_load_total = 0

    with httpx.Client(headers={"User-Agent": "f1-dbt-learning/0.3"}) as client:
        for year in args.year:
            year_cache = RAW_CACHE_DIR / str(year)
            print(f"\n=== Checking OpenF1 {year} season metadata ===", flush=True)
            meetings = fetch_json(
                client,
                "meetings",
                {"year": year},
                year_cache / "meetings.json",
                force_refresh=args.refresh or args.refresh_metadata,
            )
            sessions = fetch_json(
                client,
                "sessions",
                {"year": year, "session_name": "Race"},
                year_cache / "race_sessions.json",
                force_refresh=args.refresh or args.refresh_metadata,
            )

            sessions = [s for s in sessions if _is_completed_session(s, now_utc)]
            sessions = sorted(sessions, key=lambda s: s.get("date_start") or "")
            if args.limit > 0 and explicit_keys is None:
                sessions = sessions[: args.limit]

            if explicit_keys is not None:
                target_sessions = [s for s in sessions if int(s["session_key"]) in explicit_keys]
            else:
                target_sessions = [s for s in sessions if int(s["session_key"]) not in loaded_keys]

            skipped = len(sessions) - len(target_sessions)
            print(
                f"Found {len(sessions)} completed race(s) for {year}: "
                f"{len(target_sessions)} to load, {skipped} already loaded.",
                flush=True,
            )

            if not target_sessions:
                continue

            sessions_to_load_total += len(target_sessions)
            meeting_keys = {s["meeting_key"] for s in target_sessions if "meeting_key" in s}
            collected["meetings"].extend([m for m in meetings if m.get("meeting_key") in meeting_keys])
            collected["sessions"].extend(target_sessions)

            for idx, session in enumerate(target_sessions, start=1):
                session_key = session["session_key"]
                location = session.get("location") or session.get("country_name") or str(session_key)
                session_dir = year_cache / f"session_{session_key}"
                cached_count = sum(1 for ep in per_session_endpoints if (session_dir / f"{ep}.json").exists())
                status_tag = "cached" if cached_count == len(per_session_endpoints) and not args.refresh else "fetching"
                print(
                    f"[{year} {idx}/{len(target_sessions)}] {location} (session_key={session_key}, {status_tag})...",
                    flush=True,
                )
                for ep in per_session_endpoints:
                    rows = fetch_json(
                        client,
                        ep,
                        {"session_key": session_key},
                        session_dir / f"{ep}.json",
                        force_refresh=args.refresh,
                    )
                    collected[ep].extend(rows)

    if sessions_to_load_total == 0:
        print("\nAlready up to date — 0 new sessions to load.", flush=True)
        return

    print(f"\nLoading {sessions_to_load_total} session(s) into {args.db_path}...", flush=True)
    load_into_duckdb(collected, args.db_path, full_refresh=args.full_refresh)
    print("Done!", flush=True)


if __name__ == "__main__":
    main()
