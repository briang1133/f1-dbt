with source as (
    select * from {{ source('openf1', 'drivers') }}
),

renamed as (
    select
        cast(session_key as varchar) || '-' || cast(driver_number as varchar) as driver_session_id,
        cast(session_key as bigint) as session_key,
        cast(meeting_key as bigint) as meeting_key,
        cast(driver_number as integer) as driver_number,
        name_acronym as driver_acronym,
        full_name,
        first_name,
        last_name,
        broadcast_name,
        team_name,
        case
            when team_colour is not null then '#' || team_colour
        end as team_colour_hex,
        _ingested_at
    from source
)

select * from renamed
