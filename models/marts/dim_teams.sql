{{
    config(
        materialized='table',
        contract={'enforced': true},
    )
}}

with drivers as (
    select * from {{ ref('stg_openf1__drivers') }}
),

sessions as (
    select * from {{ ref('stg_openf1__sessions') }}
),

team_rollup as (
    select
        drivers.team_name,
        max(drivers.team_colour_hex) as team_colour_hex,
        cast(count(distinct drivers.session_key) as integer) as races_entered,
        cast(count(distinct drivers.driver_number) as integer) as distinct_drivers_used,
        string_agg(distinct drivers.driver_acronym, ', ' order by drivers.driver_acronym) as driver_roster,
        min(sessions.session_date) as first_race_date,
        max(sessions.session_date) as latest_race_date
    from drivers
    inner join sessions
        on drivers.session_key = sessions.session_key
    group by drivers.team_name
)

select * from team_rollup
