select *
from analytics.int_team_pit_stops
order by session_date desc, lap_number, stop_duration_seconds asc nulls last
