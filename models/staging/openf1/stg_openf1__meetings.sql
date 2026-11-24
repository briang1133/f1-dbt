with source as (
    select * from {{ source('openf1', 'meetings') }}
),

renamed as (
    select
        cast(meeting_key as bigint) as meeting_key,
        meeting_name,
        meeting_official_name,
        location,
        country_code,
        country_name,
        cast(circuit_key as bigint) as circuit_key,
        circuit_short_name,
        circuit_type,
        cast(year as integer) as season_year,
        cast(is_cancelled as boolean) as is_cancelled,
        cast(date_start as timestamp) as meeting_started_at,
        cast(date_end as timestamp) as meeting_ended_at,
        cast(date_start as date) as meeting_date,
        _ingested_at
    from source
)

select * from renamed
