-- =====================================================================
-- 04_staging_departures.sql
-- Purpose : type, de-duplicate and clean raw.departures into staging.departures
--           One row per flight (latest snapshot wins).
--           Column list is identical to staging.arrivals (see D6 there).
--
-- Cleaning decisions specific to departures:
--   D7  actualtakeofftime is missing for ~56% of departures. It is kept
--       as runway_time for taxi-out analysis but actual_time (off-block)
--       is the authoritative departure timestamp for delay metrics.
--   D8  checkinallocationfrom/to are desk ranges (e.g. N101 to N232),
--       null for ~26% of flights. Kept for check-in zone analysis.
-- =====================================================================

DROP TABLE IF EXISTS staging.departures;

CREATE TABLE staging.departures AS
SELECT DISTINCT ON (aodbuniquefield)
    aodbuniquefield::bigint                                   AS flight_id,
    'D'::char(1)                                              AS direction,
    NULLIF(TRIM(flightnumber), '')                            AS flight_number,
    NULLIF(TRIM(airlinecode_icao), '')                        AS airline_icao,
    NULLIF(TRIM(airlinecode_iata), '')                        AS airline_iata,
    NULLIF(TRIM(airlinename), '')                             AS airline_name_raw,
    NULLIF(TRIM(aircraft_icao), '')                           AS aircraft_type,
    NULLIF(TRIM(aircraft_iata), '')                           AS aircraft_type_iata,
    NULLIF(TRIM(aircraftregistration), '')                    AS registration,
    NULLIF(TRIM(aircraftterminal), '')                        AS terminal,           -- D3
    NULLIF(TRIM(aircraftparkingposition), '')                 AS stand,
    NULLIF(TRIM(publicgatenumber), '')                        AS gate,               -- departures only
    NULL::text                                                AS baggage_belt,       -- arrivals only
    NULLIF(TRIM(checkinallocationfrom), '')                   AS checkin_from,       -- D8
    NULLIF(TRIM(checkinallocationto), '')                     AS checkin_to,         -- D8
    -- "station" is the other end of the flight: destination for departures
    NULLIF(TRIM(destination_iata), '')                        AS station_iata,
    NULLIF(TRIM(destination_icao), '')                        AS station_icao,
    NULLIF(TRIM(destinationname), '')                         AS station_name,
    NULLIF(TRIM(via_iata), '')                                AS via_iata,
    NULLIF(TRIM(vianame), '')                                 AS via_name,
    NULLIF(TRIM(publicscheduleddatetime), '')::timestamp      AS public_sched_time,
    NULLIF(TRIM(scheduledoffblocktime), '')::timestamp        AS sched_time,         -- D6
    NULLIF(TRIM(estimatedoffblocktime), '')::timestamp        AS est_time,
    NULLIF(TRIM(actualoffblocktime), '')::timestamp           AS actual_time,        -- D7
    NULLIF(TRIM(actualtakeofftime), '')::timestamp            AS runway_time,        -- take-off, D7
    NULL::timestamp                                           AS ten_mile_out,       -- arrivals only
    NULLIF(TRIM(flightstatus), '')                            AS flight_status,
    NULLIF(TRIM(flightstatuscode), '')                        AS status_code,
    NULLIF(TRIM(traffictype), '')                             AS traffic_type,
    NULLIF(TRIM(traffictypecode), '')                         AS traffic_type_code,
    string_to_array(NULLIF(TRIM(jointflightnumber), ''), E'\t') AS codeshares,       -- D5
    NULLIF(TRIM(lastchanged), '')::timestamp                  AS last_changed,
    NULLIF(TRIM(load_timestamp), '')::timestamp               AS loaded_at
FROM raw.departures
WHERE NULLIF(TRIM(aodbuniquefield), '') IS NOT NULL
ORDER BY aodbuniquefield, NULLIF(TRIM(load_timestamp), '')::timestamp DESC NULLS LAST;   -- D1

ALTER TABLE staging.departures ADD PRIMARY KEY (flight_id);
CREATE INDEX ON staging.departures (sched_time);
CREATE INDEX ON staging.departures (registration, actual_time);

-- ---------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                            AS flights,
    (SELECT COUNT(*) FROM raw.departures)               AS raw_rows,
    (SELECT COUNT(*) FROM raw.departures) - COUNT(*)    AS snapshot_dupes_removed,
    MIN(sched_time)                                     AS first_sched,
    MAX(sched_time)                                     AS last_sched,
    COUNT(*) FILTER (WHERE actual_time IS NULL)         AS no_offblock_time,
    COUNT(*) FILTER (WHERE runway_time IS NULL)         AS no_takeoff_time,   -- expect ~56%
    COUNT(DISTINCT terminal)                            AS terminals,         -- expect 1, 2, 3, PT (arrivals also carry 2 rows of 'No')
    COUNT(DISTINCT airline_icao)                        AS airlines,
    COUNT(DISTINCT registration)                        AS aircraft
FROM staging.departures;
