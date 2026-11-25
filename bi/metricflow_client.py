"""Local MetricFlow semantic engine wired directly to DuckDB (read-only).

Reads dbt v2's compiled `target/semantic_manifest.json` and executes MetricFlow
queries against `data/f1.duckdb` in read-only mode so it runs cleanly alongside
`dct serve` and never holds write locks on the database file.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import duckdb
from metricflow.data_table.mf_table import MetricFlowDataTable
from metricflow.engine.metricflow_engine import MetricFlowEngine, MetricFlowQueryRequest
from metricflow.protocols.sql_client import SqlClient, SqlEngine
from metricflow.sql.render.duckdb_renderer import DuckDbSqlPlanRenderer
from metricflow_semantics.model.dbt_manifest_parser import (
    parse_manifest_from_dbt_generated_manifest,
)
from metricflow_semantics.model.semantic_manifest_lookup import SemanticManifestLookup
from metricflow_semantics.sql.sql_bind_parameters import SqlBindParameterSet
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST_PATH = REPO_ROOT / "target" / "semantic_manifest.json"
DEFAULT_DB_PATH = REPO_ROOT / "data" / "f1.duckdb"


class ReadOnlyDuckDBSqlClient(SqlClient):
    """Minimal read-only DuckDB SqlClient implementation for MetricFlow."""

    def __init__(self, db_path: Path) -> None:
        self._db_path = db_path
        self._renderer = DuckDbSqlPlanRenderer()

    @property
    def sql_engine_type(self) -> SqlEngine:
        return SqlEngine.DUCKDB

    @property
    def sql_plan_renderer(self) -> DuckDbSqlPlanRenderer:
        return self._renderer

    def render_bind_parameter_key(self, bind_parameter_key: str) -> str:
        return f"${bind_parameter_key}"

    def _connect(self) -> duckdb.DuckDBPyConnection:
        return duckdb.connect(str(self._db_path), read_only=True)

    def _bind_params(self, sql_bind_parameter_set: SqlBindParameterSet) -> dict[str, Any]:
        return {item.key: item.value.str_value for item in sql_bind_parameter_set.param_items}

    def query(
        self,
        stmt: str,
        sql_bind_parameter_set: SqlBindParameterSet = SqlBindParameterSet(),
    ) -> MetricFlowDataTable:
        con = self._connect()
        try:
            params = self._bind_params(sql_bind_parameter_set)
            cursor = con.execute(stmt, params) if params else con.execute(stmt)
            cols = [desc[0] for desc in (cursor.description or [])]
            rows = cursor.fetchall()
            return MetricFlowDataTable.create_from_rows(column_names=cols, rows=rows)
        finally:
            con.close()

    def execute(
        self,
        stmt: str,
        sql_bind_parameter_set: SqlBindParameterSet = SqlBindParameterSet(),
    ) -> None:
        raise NotImplementedError("ReadOnlyDuckDBSqlClient does not permit write statements.")

    def dry_run(
        self,
        stmt: str,
        sql_bind_parameter_set: SqlBindParameterSet = SqlBindParameterSet(),
    ) -> None:
        con = self._connect()
        try:
            params = self._bind_params(sql_bind_parameter_set)
            con.execute(f"EXPLAIN {stmt}", params) if params else con.execute(f"EXPLAIN {stmt}")
        finally:
            con.close()

    def close(self) -> None:
        return None


@dataclass(frozen=True)
class SemanticQueryResult:
    dataframe: pd.DataFrame
    compiled_sql: str


class F1SemanticLayer:
    """High-level wrapper around MetricFlowEngine for interactive BI exploration."""

    def __init__(
        self,
        manifest_path: Path = DEFAULT_MANIFEST_PATH,
        db_path: Path = DEFAULT_DB_PATH,
    ) -> None:
        if not manifest_path.exists():
            raise FileNotFoundError(
                f"Semantic manifest not found at {manifest_path}. Run `dbt build` or `dbt parse` first."
            )
        if not db_path.exists():
            raise FileNotFoundError(
                f"DuckDB database not found at {db_path}. Run `scripts/ingest_openf1.py` and `dbt build` first."
            )
        manifest = parse_manifest_from_dbt_generated_manifest(
            manifest_path.read_text(encoding="utf-8")
        )
        self._lookup = SemanticManifestLookup(manifest)
        self._sql_client = ReadOnlyDuckDBSqlClient(db_path)
        self._engine = MetricFlowEngine(
            semantic_manifest_lookup=self._lookup,
            sql_client=self._sql_client,
        )

    def list_metrics(self) -> list[dict[str, Any]]:
        metrics = self._engine.list_metrics()
        return [
            {
                "name": m.name,
                "label": m.label or m.name,
                "type": str(m.type.value if hasattr(m.type, "value") else m.type),
                "description": m.description or "",
            }
            for m in sorted(metrics, key=lambda x: x.name)
        ]

    def list_dimensions(self, metric_names: Sequence[str]) -> list[dict[str, Any]]:
        dims = self._engine.list_dimensions(metric_names=list(metric_names))
        return [
            {
                "dunder_name": d.dunder_name,
                "name": d.name,
                "type": str(d.type.value if hasattr(d.type, "value") else d.type),
                "description": d.description or "",
            }
            for d in sorted(dims, key=lambda x: x.dunder_name)
        ]

    def get_dimension_values(
        self,
        metric_names: Sequence[str],
        dimension_dunder_name: str,
    ) -> list[str]:
        """Fetch sorted distinct values for any semantic dimension via MetricFlow."""
        values = self._engine.get_dimension_values(
            metric_names=list(metric_names),
            get_group_by_values=dimension_dunder_name,
        )
        return sorted({str(v) for v in values if v is not None})

    @staticmethod
    def build_dimension_filter(
        dimension_dunder_name: str,
        dimension_type: str,
        values: Sequence[str],
        exclude: bool = False,
    ) -> str:
        """Build a valid MetricFlow Jinja WHERE clause from UI-selected dimension values."""
        op = "NOT IN" if exclude else "IN"
        dim_type_lower = dimension_type.lower()

        if dim_type_lower == "time" or dimension_dunder_name.startswith("metric_time"):
            base_dim = dimension_dunder_name.split("__")[0] if dimension_dunder_name.startswith("metric_time") else dimension_dunder_name
            date_literals = ", ".join(f"DATE '{v[:10]}'" for v in values)
            return f"{{{{ TimeDimension('{base_dim}', 'day') }}}} {op} ({date_literals})"

        # Emit numeric literals when all values are plain integers (e.g. season_year)
        if values and all(v.lstrip("-").isdigit() for v in values):
            formatted = ", ".join(values)
        else:
            formatted = ", ".join("'" + v.replace("'", "''") + "'" for v in values)
        return f"{{{{ Dimension('{dimension_dunder_name}') }}}} {op} ({formatted})"

    def list_saved_queries(self) -> list[dict[str, Any]]:
        saved = self._engine.list_saved_queries()
        return [
            {
                "name": sq.name,
                "description": sq.description or "",
                "metrics": list(sq.query_params.metrics),
                "group_by": list(sq.query_params.group_by),
            }
            for sq in sorted(saved, key=lambda x: x.name)
        ]

    def run_query(
        self,
        metrics: Sequence[str],
        group_by: Sequence[str] = (),
        where_constraints: Sequence[str] = (),
        order_by: Sequence[str] = (),
        limit: int | None = None,
    ) -> SemanticQueryResult:
        request = MetricFlowQueryRequest.create(
            metric_names=list(metrics),
            group_by_names=list(group_by),
            where_constraints=list(where_constraints) or None,
            order_by_names=list(order_by) or None,
            limit=limit,
        )
        explain = self._engine.explain(request)
        compiled_sql = explain.sql_statement.sql
        result = self._engine.query(request)
        df = self._to_dataframe(result.result_df)
        return SemanticQueryResult(dataframe=df, compiled_sql=compiled_sql)

    def run_saved_query(self, saved_query_name: str) -> SemanticQueryResult:
        request = MetricFlowQueryRequest.create(
            saved_query_name=saved_query_name,
        )
        explain = self._engine.explain(request)
        compiled_sql = explain.sql_statement.sql
        result = self._engine.query(request)
        df = self._to_dataframe(result.result_df)
        return SemanticQueryResult(dataframe=df, compiled_sql=compiled_sql)

    @staticmethod
    def _to_dataframe(mf_table: MetricFlowDataTable | None) -> pd.DataFrame:
        if mf_table is None:
            return pd.DataFrame()
        cols = list(mf_table.column_names)
        rows = [
            [mf_table.get_cell_value(row_idx, col_idx) for col_idx in range(mf_table.column_count)]
            for row_idx in range(mf_table.row_count)
        ]
        return pd.DataFrame(rows, columns=cols)
