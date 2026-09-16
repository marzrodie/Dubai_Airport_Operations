-- =====================================================================
-- 03_staging_arrivals.sql
-- Purpose : type, de-duplicate and clean raw.arrivals into staging.arrivals
--           One row per flight (latest snapshot wins).
--
-- Cleaning decisions (mirror these in the README):
--   D1  Keep the latest load_timestamp per aodbuniquefield.
--       A handful of flights were exported twice as their status changed.
--   D2  Empty strings become NULL before casting (NULLIF).
--   D3  aircraftterminal has trailing spaces ('3 ' vs '3'). TRIM it.
--   D4  Airline names are inconsistent ('Flydubai' vs 'Fly dubai').
--       The ICAO code is the key; the display name is standardised
--       later in 05_movements.sql from a dimension table.
--   D5  Codeshare flight numbers arrive tab-separated in one cell.
--       Split into a text[] so they can be counted or unnested.
--   D6  Column names are aligned with staging.departures so the two
--       tables can be UNIONed: sched_time / est_time / actual_time
--       always mean the block time (in-block for arrivals,
--       off-block for departures); runway_time is landing or take-off.
-- =====================================================================

DROP TABLE IF EXISTS staging.arrivals;

CREATE TABLE staging.arrivals AS
SELECT DISTINCT ON (aodbuniquefield)
    aodbuniquefield::bigint                                   AS flight_id,
    'A'::char(1)                                              AS direction,
    NULLIF(TRIM(flightnumber), '')                            AS flight_number,
    NULLIF(TRIM(airlinecode_icao), '')                        AS airline_icao,
    NULLIF(TRIM(airlinecode_iata), '')                        AS airline_iata,
    NULLIF(TRIM(airlinename), '')                             AS airline_name_raw,
    NULLIF(TRIM(aircraft_icao), '')                           AS aircraft_type,
    NULLIF(TRIM(aircraft_iata), '')                           AS aircraft_type_iata,
    NULLIF(TRIM(aircraftregistration), '')                    AS registration,
    NULLIF(TRIM(aircraftterminal), '')                        AS terminal,           -- D3
    NULLIF(TRIM(aircraftparkingposition), '')                 AS stand,
    NULL::text                                                AS gate,               -- departures only
    NULLIF(TRIM(baggageclaimunit), '')                        AS baggage_belt,       -- arrivals only
    NULL::text                                                AS checkin_from,       -- departures only
    NULL::text                                                AS checkin_to,         -- departures only
    -- "station" is the other end of the flight: origin for arrivals
    NULLIF(TRIM(origin_iata), '')                             AS station_iata,
    NULLIF(TRIM(origin_icao), '')                             AS station_icao,
    NULLIF(TRIM(originname), '')                              AS station_name,
    NULLIF(TRIM(via_iata), '')                                AS via_iata,
    NULLIF(TRIM(vianame), '')                                 AS via_name,
    NULLIF(TRIM(publicscheduleddatetime), '')::timestamp      AS public_sched_time,
    NULLIF(TRIM(scheduledinblocktime), '')::timestamp         AS sched_time,         -- D6
    NULLIF(TRIM(estimatedinblocktime), '')::timestamp         AS est_time,
    NULLIF(TRIM(actualinblocktime), '')::timestamp            AS actual_time,
    NULLIF(TRIM(actuallandingtime), '')::timestamp            AS runway_time,        -- landing
    NULLIF(TRIM(tenmileout), '')::timestamp                   AS ten_mile_out,       -- arrivals only
    NULLIF(TRIM(flightstatus), '')                            AS flight_status,
    NULLIF(TRIM(flightstatuscode), '')                        AS status_code,
    NULLIF(TRIM(traffictype), '')                             AS traffic_type,
    NULLIF(TRIM(traffictypecode), '')                         AS traffic_type_code,
    string_to_array(NULLIF(TRIM(jointflightnumber), ''), E'\t') AS codeshares,       -- D5
    NULLIF(TRIM(lastchanged), '')::timestamp                  AS last_changed,
    NULLIF(TRIM(load_timestamp), '')::timestamp               AS loaded_at
FROM raw.arrivals
WHERE NULLIF(TRIM(aodbuniquefield), '') IS NOT NULL
ORDER BY aodbuniquefield, NULLIF(TRIM(load_timestamp), '')::timestamp DESC NULLS LAST;   -- D1

ALTER TABLE staging.arrivals ADD PRIMARY KEY (flight_id);
CREATE INDEX ON staging.arrivals (sched_time);
CREATE INDEX ON staging.arrivals (registration, actual_time);

-- ---------------------------------------------------------------------
-- Validation (run after the CREATE; paste the results into the README)
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                            AS flights,
    (SELECT COUNT(*) FROM raw.arrivals)                 AS raw_rows,
    (SELECT COUNT(*) FROM raw.arrivals) - COUNT(*)      AS snapshot_dupes_removed,
    MIN(sched_time)                                     AS first_sched,
    MAX(sched_time)                                     AS last_sched,
    COUNT(*) FILTER (WHERE actual_time IS NULL)         AS no_actual_time,
    COUNT(DISTINCT terminal)                            AS terminals,        -- expect 1, 2, 3, PT (arrivals also carry 2 rows of 'No')
    COUNT(DISTINCT airline_icao)                        AS airlines,
    COUNT(DISTINCT registration)                        AS aircraft
FROM staging.arrivals;
