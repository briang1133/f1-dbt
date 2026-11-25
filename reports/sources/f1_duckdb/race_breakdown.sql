select *
from analytics.fct_driver_race_breakdown
order by race_date desc, finish_position asc nulls last
