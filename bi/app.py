"""Interactive F1 Semantic Layer Explorer powered by MetricFlow + DuckDB + Streamlit.

Run locally with:
    uv run --extra bi streamlit run bi/app.py --server.port 8501
"""

from __future__ import annotations

from pathlib import Path
import sys

import duckdb
import pandas as pd
import plotly.express as px
import streamlit as st

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bi.metricflow_client import DEFAULT_DB_PATH, DEFAULT_MANIFEST_PATH, F1SemanticLayer  # noqa: E402

st.set_page_config(
    page_title="F1 dbt Semantic Layer Explorer",
    page_icon="🏎️",
    layout="wide",
)


@st.cache_resource
def load_semantic_layer(manifest_mtime: float, client_mtime: float) -> F1SemanticLayer:
    """Cache MetricFlow engine keyed by manifest and client mtime so edits reload cleanly."""
    _ = (manifest_mtime, client_mtime)
    return F1SemanticLayer()


@st.cache_data(ttl=60)
def load_filter_metadata(db_mtime: float) -> tuple[list[int], list[str], dict[str, str]]:
    """Fetch available seasons, teams, and official team hex colors in read-only mode."""
    _ = db_mtime
    con = duckdb.connect(str(DEFAULT_DB_PATH), read_only=True)
    try:
        seasons = [
            int(r[0])
            for r in con.execute(
                "SELECT DISTINCT season_year FROM analytics.fct_team_race_performance ORDER BY 1 DESC"
            ).fetchall()
        ]
        team_rows = con.execute(
            "SELECT team_name, team_colour_hex FROM analytics.dim_teams ORDER BY team_name"
        ).fetchall()
        teams = [r[0] for r in team_rows]
        colors = {r[0]: r[1] for r in team_rows if r[1]}
        return seasons, teams, colors
    finally:
        con.close()


@st.cache_data(ttl=60)
def load_dimension_values(
    manifest_mtime: float,
    client_mtime: float,
    db_mtime: float,
    metrics_key: tuple[str, ...],
    dim_dunder_name: str,
) -> list[str]:
    """Cache MetricFlow distinct dimension values for snappy filter dropdowns."""
    _ = db_mtime
    sl = load_semantic_layer(manifest_mtime, client_mtime)
    return sl.get_dimension_values(metrics_key, dim_dunder_name)


def pretty_dimension_label(dim_dunder_name: str) -> str:
    """Format a MetricFlow dunder dimension name into a readable dropdown label."""
    parts = dim_dunder_name.split("__")
    if len(parts) == 2:
        entity, attr = parts
        return f"{attr.replace('_', ' ').title()} ({entity})"
    return dim_dunder_name.replace("_", " ").title()


def build_saved_query_yaml(
    query_name: str,
    description: str,
    metrics: list[str],
    group_by: list[str],
    dim_meta_by_name: dict[str, dict[str, str]],
    where_clauses: list[str],
) -> str:
    """Format the current Metric Explorer state as a valid dbt v2 saved_queries YAML block."""
    safe_name = (
        "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in query_name.strip().lower()).strip("_")
        or "my_saved_query"
    )
    lines = [
        "saved_queries:",
        f"  - name: {safe_name}",
        f"    description: {description.strip() or 'Custom F1 semantic query.'}",
        "    query_params:",
        "      metrics:",
    ]
    for m in metrics:
        lines.append(f"        - {m}")

    if group_by:
        lines.append("      group_by:")
        for dim in group_by:
            if dim.startswith("metric_time__"):
                grain = dim.split("__", 1)[1]
                lines.append(f"        - TimeDimension('metric_time', '{grain}')")
            elif dim_meta_by_name.get(dim, {}).get("type", "").lower() == "time":
                lines.append(f"        - TimeDimension('{dim}', 'day')")
            else:
                lines.append(f"        - Dimension('{dim}')")

    if where_clauses:
        lines.append("      where:")
        for clause in where_clauses:
            escaped = clause.replace('"', '\\"')
            lines.append(f'        - "{escaped}"')

    return "\n".join(lines)


def format_metric_value(metric_name: str, value: float | int | None) -> str:
    if value is None or pd.isna(value):
        return "—"
    if metric_name.endswith("_rate"):
        return f"{value * 100:.1f}%"
    if "seconds" in metric_name:
        return f"{value:.2f}s"
    if metric_name in {"team_points", "races_run", "double_points_races", "total_service_pit_stops",
                       "total_elite_pit_stops", "total_dnfs", "fastest_stop_awards"}:
        return f"{value:,.0f}"
    return f"{value:,.2f}"


def render_chart(
    df: pd.DataFrame,
    metrics: list[str],
    group_by: list[str],
    chart_type: str,
    team_colors: dict[str, str],
) -> None:
    if df.empty or not metrics:
        st.info("No rows returned for this selection.")
        return

    y_col = metrics[0]
    dim_cols = [c for c in df.columns if c not in metrics]
    if not dim_cols:
        return

    x_col = dim_cols[0]
    color_col = dim_cols[1] if len(dim_cols) > 1 else (
        x_col if x_col.endswith("team_name") else None
    )
    color_map = team_colors if (color_col and color_col.endswith("team_name")) else None

    if chart_type == "Bar":
        fig = px.bar(
            df,
            x=x_col,
            y=y_col if len(metrics) == 1 or len(dim_cols) > 1 else metrics,
            color=color_col if (len(metrics) == 1 or len(dim_cols) > 1) else None,
            color_discrete_map=color_map,
            barmode="group",
        )
    elif chart_type == "Line":
        fig = px.line(
            df.sort_values(x_col),
            x=x_col,
            y=y_col,
            color=color_col if color_col != x_col else None,
            color_discrete_map=color_map,
            markers=True,
        )
    elif chart_type == "Scatter" and len(metrics) >= 2:
        fig = px.scatter(
            df,
            x=metrics[0],
            y=metrics[1],
            color=x_col,
            color_discrete_map=team_colors if x_col.endswith("team_name") else None,
            hover_data=dim_cols + metrics,
            size_max=18,
        )
        fig.update_traces(marker=dict(size=12))
    else:
        return

    fig.update_layout(height=420, margin=dict(l=20, r=20, t=30, b=20))
    st.plotly_chart(fig, use_container_width=True)


def main() -> None:
    st.title("🏎️ F1 dbt Semantic Layer Explorer")
    st.caption(
        "Open-source **MetricFlow** + **DuckDB (read-only)** querying your dbt v2 "
        "`target/semantic_manifest.json` directly — zero dbt Cloud, zero Docker."
    )

    if not DEFAULT_MANIFEST_PATH.exists() or not DEFAULT_DB_PATH.exists():
        st.error(
            "Missing `target/semantic_manifest.json` or `data/f1.duckdb`. "
            "Run `uv run python scripts/ingest_openf1.py` and `dbt build` first."
        )
        st.stop()

    manifest_mtime = DEFAULT_MANIFEST_PATH.stat().st_mtime
    client_mtime = (REPO_ROOT / "bi" / "metricflow_client.py").stat().st_mtime
    db_mtime = DEFAULT_DB_PATH.stat().st_mtime
    sl = load_semantic_layer(manifest_mtime, client_mtime)
    seasons, _teams, team_colors = load_filter_metadata(db_mtime)
    all_metrics = sl.list_metrics()
    metric_by_name = {m["name"]: m for m in all_metrics}

    tab_explore, tab_saved, tab_catalog = st.tabs(
        ["🔍 Metric Explorer", "📌 Saved Queries", "📚 Semantic Catalog"]
    )

    with tab_explore:
        with st.sidebar:
            st.header("Query Builder")
            if st.button("↻ Reload dbt Manifest", use_container_width=True):
                st.cache_resource.clear()
                st.cache_data.clear()
                st.rerun()

            selected_metrics = st.multiselect(
                "Metrics",
                options=[m["name"] for m in all_metrics],
                default=["team_points", "points_per_race", "avg_pit_stop_seconds", "elite_pit_stop_rate"],
                format_func=lambda name: f"{metric_by_name[name]['label']} ({metric_by_name[name]['type']})",
            )

            available_dims = sl.list_dimensions(selected_metrics) if selected_metrics else []
            dim_meta_by_name = {d["dunder_name"]: d for d in available_dims}
            dim_options = [d["dunder_name"] for d in available_dims]
            # Expose helpful time granularities on metric_time
            for grain in ["metric_time__month", "metric_time__week", "metric_time__year"]:
                if "metric_time__day" in dim_options and grain not in dim_options:
                    dim_options.insert(dim_options.index("metric_time__day") + 1, grain)

            default_dims = ["team_race__team_name"] if "team_race__team_name" in dim_options else []
            selected_dims = st.multiselect(
                "Group By Dimensions",
                options=dim_options,
                default=default_dims,
                format_func=pretty_dimension_label,
            )

            st.divider()
            st.subheader("Filters (No-Code)")
            season_choice = st.selectbox("Season", options=["All", *seasons], index=1 if seasons else 0)

            filterable_dims = [
                d["dunder_name"]
                for d in available_dims
                if d["dunder_name"] != "team_race__season_year"
                and not d["dunder_name"].startswith("metric_time")
            ]
            chosen_filter_dims = st.multiselect(
                "Filter by Dimension(s)",
                options=filterable_dims,
                default=[],
                format_func=pretty_dimension_label,
                placeholder="Choose any dimension (Circuit, Team, Country...)",
            )

            dynamic_where_clauses: list[str] = []
            for f_dim in chosen_filter_dims:
                f_type = dim_meta_by_name[f_dim]["type"]
                raw_vals = load_dimension_values(
                    manifest_mtime,
                    client_mtime,
                    db_mtime,
                    tuple(selected_metrics),
                    f_dim,
                )
                display_vals = [v[:10] for v in raw_vals] if f_type.lower() == "time" else raw_vals
                with st.container(border=True):
                    st.markdown(f"**{pretty_dimension_label(f_dim)}**")
                    match_mode = st.radio(
                        f"Match mode for {f_dim}",
                        options=["Include", "Exclude"],
                        horizontal=True,
                        label_visibility="collapsed",
                        key=f"filter_mode_{f_dim}",
                    )
                    picked_vals = st.multiselect(
                        f"Values for {f_dim}",
                        options=display_vals,
                        default=[],
                        label_visibility="collapsed",
                        placeholder="Select values...",
                        key=f"filter_vals_{f_dim}",
                    )
                if picked_vals:
                    dynamic_where_clauses.append(
                        sl.build_dimension_filter(
                            f_dim,
                            f_type,
                            picked_vals,
                            exclude=(match_mode == "Exclude"),
                        )
                    )

            with st.expander("Advanced: MetricFlow WHERE", expanded=False):
                custom_where = st.text_input(
                    "Extra MetricFlow WHERE (optional)",
                    placeholder="{{ Dimension('team_race__circuit_short_name') }} = 'Las Vegas'",
                )

            st.divider()
            order_choices = ["(Default)"] + [f"-{m}" for m in selected_metrics] + list(selected_metrics) + list(selected_dims)
            order_by_choice = st.selectbox(
                "Order By",
                options=order_choices,
                index=1 if selected_metrics else 0,
            )
            row_limit = st.number_input("Row Limit", min_value=1, max_value=1000, value=100, step=10)

        if not selected_metrics:
            st.warning("Select at least one metric in the sidebar to run a MetricFlow query.")
        else:
            where_clauses: list[str] = []
            if season_choice != "All":
                where_clauses.append(f"{{{{ Dimension('team_race__season_year') }}}} = {int(season_choice)}")
            where_clauses.extend(dynamic_where_clauses)
            if custom_where.strip():
                where_clauses.append(custom_where.strip())

            if where_clauses:
                with st.sidebar:
                    with st.expander("Active MetricFlow WHERE clauses", expanded=False):
                        for clause in where_clauses:
                            st.code(clause, language="sql")

            order_by = [] if order_by_choice == "(Default)" else [order_by_choice]

            try:
                res = sl.run_query(
                    metrics=selected_metrics,
                    group_by=selected_dims,
                    where_constraints=where_clauses,
                    order_by=order_by,
                    limit=int(row_limit),
                )
            except Exception as exc:
                st.error(f"MetricFlow query error: {exc}")
                st.stop()

            # Top-level KPIs (un-grouped aggregate for the current filters)
            if selected_dims:
                try:
                    kpi_res = sl.run_query(
                        metrics=selected_metrics[:4],
                        group_by=[],
                        where_constraints=where_clauses,
                    )
                    if not kpi_res.dataframe.empty:
                        cols = st.columns(len(selected_metrics[:4]))
                        for idx, m_name in enumerate(selected_metrics[:4]):
                            val = kpi_res.dataframe[m_name].iloc[0]
                            cols[idx].metric(
                                label=metric_by_name[m_name]["label"],
                                value=format_metric_value(m_name, val),
                            )
                except Exception:
                    pass

            # Chart selector
            if selected_dims:
                is_time_x = selected_dims[0].startswith("metric_time") or selected_dims[0].endswith("race_date")
                default_chart_idx = 1 if is_time_x else 0
                chart_options = ["Bar", "Line", "Scatter", "Table Only"]
                chart_type = st.radio(
                    "Visualization",
                    options=chart_options,
                    index=default_chart_idx,
                    horizontal=True,
                )
                if chart_type != "Table Only":
                    render_chart(res.dataframe, selected_metrics, selected_dims, chart_type, team_colors)

            st.subheader("Query Results")
            st.dataframe(res.dataframe, use_container_width=True, hide_index=True)

            col_dl, col_count = st.columns([1, 3])
            with col_dl:
                st.download_button(
                    "Download CSV",
                    data=res.dataframe.to_csv(index=False).encode("utf-8"),
                    file_name="f1_metricflow_query.csv",
                    mime="text/csv",
                )
            with col_count:
                st.caption(f"{len(res.dataframe):,} row(s) returned via MetricFlow → DuckDB.")

            with st.expander("💾 Export as dbt Saved Query YAML", expanded=False):
                st.caption(
                    "Paste this into `models/marts/_marts__models.yml` under `saved_queries:`, "
                    "run `dbt parse`, then click **↻ Reload dbt Manifest** in the sidebar."
                )
                sq_col_name, sq_col_desc = st.columns([1, 2])
                with sq_col_name:
                    export_name = st.text_input("Saved Query Name", value="custom_team_slice")
                with sq_col_desc:
                    export_desc = st.text_input(
                        "Description",
                        value="Custom F1 team performance slice exported from Metric Explorer.",
                    )
                yaml_snippet = build_saved_query_yaml(
                    query_name=export_name,
                    description=export_desc,
                    metrics=selected_metrics,
                    group_by=selected_dims,
                    dim_meta_by_name=dim_meta_by_name,
                    where_clauses=where_clauses,
                )
                st.code(yaml_snippet, language="yaml")

            with st.expander("Compiled MetricFlow SQL (DuckDB)", expanded=False):
                st.code(res.compiled_sql, language="sql")

    with tab_saved:
        st.subheader("dbt Saved Queries")
        saved_queries = sl.list_saved_queries()
        if not saved_queries:
            st.info("No `saved_queries:` defined in your dbt project yet.")
        else:
            sq_names = [sq["name"] for sq in saved_queries]
            selected_sq = st.selectbox("Select Saved Query", options=sq_names)
            sq_meta = next(sq for sq in saved_queries if sq["name"] == selected_sq)
            st.caption(sq_meta["description"])
            st.write(
                f"**Metrics:** `{', '.join(sq_meta['metrics'])}`  |  "
                f"**Group By:** `{', '.join(sq_meta['group_by'])}`"
            )
            sq_res = sl.run_saved_query(selected_sq)
            if not sq_res.dataframe.empty and sq_meta["metrics"]:
                sq_metric_col = st.selectbox(
                    "Chart Metric",
                    options=sq_meta["metrics"],
                    format_func=lambda name: metric_by_name.get(name, {}).get("label", name),
                    key="saved_query_chart_metric",
                )
                sq_dim_cols = [c for c in sq_res.dataframe.columns if c not in sq_meta["metrics"]]
                if sq_dim_cols:
                    render_chart(
                        sq_res.dataframe.sort_values(sq_metric_col, ascending=False),
                        [sq_metric_col],
                        sq_dim_cols,
                        "Bar",
                        team_colors,
                    )
            st.dataframe(sq_res.dataframe, use_container_width=True, hide_index=True)
            with st.expander("Compiled MetricFlow SQL (DuckDB)", expanded=False):
                st.code(sq_res.compiled_sql, language="sql")

    with tab_catalog:
        st.subheader("Governed Metrics (from `target/semantic_manifest.json`)")
        st.dataframe(pd.DataFrame(all_metrics), use_container_width=True, hide_index=True)
        st.subheader("Available Dimensions for `team_points`")
        st.dataframe(
            pd.DataFrame(sl.list_dimensions(["team_points"])),
            use_container_width=True,
            hide_index=True,
        )


if __name__ == "__main__":
    main()
