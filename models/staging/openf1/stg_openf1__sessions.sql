with source as (
    select * from {{ source('openf1', 'sessions') }}
),

renamed as (
    select
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        session_name,
        session_type,
        cast(circuit_key as bigint) as circuit_key,
        circuit_short_name,
        country_code,
        country_name,
        location,
        cast(year as integer) as season_year,
        cast(is_cancelled as boolean) as is_cancelled,
        cast(date_start as timestamp) as session_started_at,
        cast(date_end as timestamp) as session_ended_at,
        cast(date_start as date) as session_date,
        _ingested_at
    from source
)

select * from renamed
