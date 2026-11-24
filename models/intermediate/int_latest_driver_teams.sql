with drivers as (
    select * from {{ ref('stg_openf1__drivers') }}
),

sessions as (
    select * from {{ ref('stg_openf1__sessions') }}
),

ranked as (
    select
        drivers.driver_number,
        drivers.driver_acronym,
        drivers.full_name,
        drivers.team_name,
        drivers.team_colour_hex,
        sessions.session_key as latest_session_key,
        sessions.session_date as latest_session_date,
        row_number() over (
            partition by drivers.driver_number
            order by sessions.session_started_at desc
        ) as recency_rank
    from drivers
    inner join sessions
        on drivers.session_key = sessions.session_key
)

select
    driver_number,
    driver_acronym,
    full_name,
    team_name,
    team_colour_hex,
    latest_session_key,
    latest_session_date
from ranked
where recency_rank = 1
