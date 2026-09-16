-- =====================================================================
-- 01_schemas_and_raw.sql
-- Purpose : create the three-layer schema and the raw landing tables.
-- Layer   : raw  = untouched copy of the Dubai Pulse CSV exports (all text)
--           staging = typed, de-duplicated, cleaned, one row per flight
--           analytics = tables the dashboards and Python scripts read
-- Run once in pgAdmin (Query Tool) or psql against database dxb_ops.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;

DROP TABLE IF EXISTS raw.arrivals;
CREATE TABLE raw.arrivals (
    actualinblocktime        text,
    actuallandingtime        text,
    aircraft_iata            text,
    aircraft_icao            text,
    aircraftparkingposition  text,
    aircraftregistration     text,
    aircraftterminal         text,
    airlinecode_iata         text,
    airlinecode_icao         text,
    airlinename              text,
    airlinenamea             text,
    aodbuniquefield          text,
    arrivalordeparture       text,
    baggageclaimunit         text,
    destination_iata         text,
    destination_icao         text,
    estimatedinblocktime     text,
    flightnumber             text,
    flightstatus             text,
    flightstatuscode         text,
    flightstatustexta        text,
    jointflightnumber        text,
    lastchanged              text,
    origin_iata              text,
    origin_icao              text,
    originname               text,
    originnamea              text,
    publicscheduleddatetime  text,
    scheduledinblocktime     text,
    tenmileout               text,
    traffictype              text,
    traffictypecode          text,
    via_iata                 text,
    via_icao                 text,
    vianame                  text,
    vianamea                 text,
    load_timestamp           text
);

DROP TABLE IF EXISTS raw.departures;
CREATE TABLE raw.departures (
    actualoffblocktime       text,
    actualtakeofftime        text,
    aircraft_iata            text,
    aircraft_icao            text,
    aircraftparkingposition  text,
    aircraftregistration     text,
    aircraftterminal         text,
    airlinecode_iata         text,
    airlinecode_icao         text,
    airlinename              text,
    airlinenamea             text,
    aodbuniquefield          text,
    arrivalordeparture       text,
    checkinallocationfrom    text,
    checkinallocationto      text,
    destination_iata         text,
    destination_icao         text,
    destinationname          text,
    destinationnamea         text,
    estimatedoffblocktime    text,
    flightnumber             text,
    flightstatus             text,
    flightstatuscode         text,
    flightstatustexta        text,
    jointflightnumber        text,
    lastchanged              text,
    publicgatenumber         text,
    publicscheduleddatetime  text,
    scheduledoffblocktime    text,
    traffictype              text,
    traffictypecode          text,
    via_iata                 text,
    via_icao                 text,
    vianame                  text,
    vianamea                 text,
    load_timestamp           text
);

-- ---------------------------------------------------------------------
-- Loading the CSVs
-- Option A (pgAdmin): right-click raw.arrivals > Import/Export Data
--   Format: csv, Header: yes, Encoding: UTF8, Delimiter: comma
-- Option B (psql, run from your machine, adjust the paths):
--   \copy raw.arrivals   FROM 'C:/data/dxb/arrivals.csv'   WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
--   \copy raw.departures FROM 'C:/data/dxb/departures.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
-- ---------------------------------------------------------------------

-- Sanity check after loading (expect ~254k and ~256k)
-- SELECT 'arrivals' AS t, COUNT(*) FROM raw.arrivals
-- UNION ALL
-- SELECT 'departures', COUNT(*) FROM raw.departures;
