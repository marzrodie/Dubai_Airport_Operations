-- =====================================================================
-- 05_movements.sql
-- Purpose : build the analytics layer
--   analytics.dim_airline        one clean display name per ICAO code
--   analytics.movements          arrivals + departures in one table with
--                                delay, taxi and quality flags
--   analytics.monthly_coverage   which months have complete data
--
-- Metric definitions (copy into the README):
--   delay_min        actual block time minus scheduled block time, minutes.
--                    Negative = early. Departures use off-block, arrivals in-block.
--   is_delayed_15    delay_min > 15 (industry OTP convention).
--   delay_outlier    delay_min < -60 or > 600. Almost always a data-entry
--                    or date-roll artefact; excluded from averages.
--   taxi_min         arrivals: in-block minus landing (taxi-in)
--                    departures: take-off minus off-block (taxi-out)
--   taxi_outlier     taxi_min < 0 or > 90.
--   is_operated      the flight actually moved (has an actual_time and a
--                    completed status). Cancelled flights have no delay.
--   coverage_complete every day of the month is present AND the average
--                    movements per day is at least MIN_PER_DAY for that
--                    direction. Volume trends must filter on this flag;
--                    per-flight rates (delay %, cancel %) do not need to.
--
-- Cleaning decision D9: aodbuniquefield is only unique WITHIN a direction.
--   83 ids appear in both files attached to unrelated flights, so the
--   movements table uses (direction, flight_id) as its key and exposes
--   movement_key = direction || '-' || flight_id for joins from Python
--   and the dashboards.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Airline dimension: the most frequent raw name per ICAO code becomes
--    the display name. Fixes 'Flydubai' / 'Fly dubai' and similar splits
--    without hard-coding every case.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM staging.arrivals) = 0 THEN
        RAISE EXCEPTION 'staging.arrivals is empty: import raw.arrivals and run 03 first';
    END IF;
    IF (SELECT COUNT(*) FROM staging.departures) = 0 THEN
        RAISE EXCEPTION 'staging.departures is empty: import raw.departures and run 04 first';
    END IF;
END $$;

DROP TABLE IF EXISTS analytics.dim_airline;

CREATE TABLE analytics.dim_airline AS
WITH names AS (
    SELECT airline_icao, airline_iata, airline_name_raw, COUNT(*) AS n
    FROM (
        SELECT airline_icao, airline_iata, airline_name_raw FROM staging.arrivals
        UNION ALL
        SELECT airline_icao, airline_iata, airline_name_raw FROM staging.departures
    ) u
    WHERE airline_icao IS NOT NULL AND airline_name_raw IS NOT NULL
    GROUP BY 1, 2, 3
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY airline_icao ORDER BY n DESC, airline_name_raw) AS rn,
           SUM(n) OVER (PARTITION BY airline_icao) AS total_movements
    FROM names
)
SELECT airline_icao,
       airline_iata,
       airline_name_raw AS airline_name,
       total_movements,
       CASE WHEN airline_icao IN ('UAE', 'FDB') THEN 'Home carrier'
            ELSE 'Foreign carrier' END AS carrier_group
FROM ranked
WHERE rn = 1;

ALTER TABLE analytics.dim_airline ADD PRIMARY KEY (airline_icao);

-- ---------------------------------------------------------------------
-- 2. Movements: union of both staging tables plus derived metrics
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.movements;

CREATE TABLE analytics.movements AS
WITH unioned AS (
    SELECT * FROM staging.arrivals
    UNION ALL
    SELECT * FROM staging.departures
),
derived AS (
    SELECT
        u.direction || '-' || u.flight_id::text            AS movement_key,   -- D9
        u.flight_id,
        u.direction,
        u.flight_number,
        u.airline_icao,
        u.airline_iata,
        COALESCE(d.airline_name, u.airline_name_raw)     AS airline_name,
        COALESCE(d.carrier_group, 'Foreign carrier')     AS carrier_group,
        u.aircraft_type,
        u.aircraft_type_iata,
        u.registration,
        u.terminal,
        u.stand,
        u.gate,
        u.baggage_belt,
        u.checkin_from,
        u.checkin_to,
        u.station_iata,
        u.station_icao,
        u.station_name,
        u.via_iata,
        u.via_name,
        (u.via_iata IS NOT NULL)                         AS is_via,
        u.public_sched_time,
        u.sched_time,
        u.est_time,
        u.actual_time,
        u.runway_time,
        u.ten_mile_out,
        u.flight_status,
        u.status_code,
        u.traffic_type,
        u.traffic_type_code,
        u.codeshares,
        COALESCE(array_length(u.codeshares, 1), 0)       AS codeshare_count,
        u.last_changed,
        u.loaded_at,
        -- calendar helpers for slicers
        u.sched_time::date                               AS sched_date,
        date_trunc('month', u.sched_time)::date          AS sched_month,
        EXTRACT(HOUR FROM u.sched_time)::int             AS sched_hour,
        EXTRACT(ISODOW FROM u.sched_time)::int           AS sched_dow,      -- 1 = Mon
        TO_CHAR(u.sched_time, 'Dy')                      AS sched_dow_name,
        -- status classification
        (u.flight_status = 'Cancelled')                  AS is_cancelled,
        (u.flight_status = 'Diverted')                   AS is_diverted,
        (u.actual_time IS NOT NULL
         AND u.flight_status IN ('Arrived', 'Departed', 'Landed')) AS is_operated,
        -- delay in minutes (block time basis)
        ROUND(EXTRACT(EPOCH FROM (u.actual_time - u.sched_time)) / 60.0, 1)      AS delay_min,
        ROUND(EXTRACT(EPOCH FROM (u.est_time    - u.sched_time)) / 60.0, 1)      AS est_delay_min,
        ROUND(EXTRACT(EPOCH FROM (u.actual_time - u.est_time))   / 60.0, 1)      AS est_error_min,
        -- taxi time in minutes
        CASE u.direction
            WHEN 'A' THEN ROUND(EXTRACT(EPOCH FROM (u.actual_time - u.runway_time)) / 60.0, 1)
            WHEN 'D' THEN ROUND(EXTRACT(EPOCH FROM (u.runway_time - u.actual_time)) / 60.0, 1)
        END                                              AS taxi_min
    FROM unioned u
    LEFT JOIN analytics.dim_airline d ON d.airline_icao = u.airline_icao
)
SELECT
    derived.*,
    (delay_min > 15)                                     AS is_delayed_15,
    (delay_min < -60 OR delay_min > 600)                 AS delay_outlier,
    (taxi_min < 0 OR taxi_min > 90)                      AS taxi_outlier,
    CASE
        WHEN delay_min IS NULL   THEN 'No actual time'
        WHEN delay_min <= 0      THEN 'On time or early'
        WHEN delay_min <= 15     THEN '1 to 15 min'
        WHEN delay_min <= 60     THEN '16 to 60 min'
        WHEN delay_min <= 180    THEN '1 to 3 hours'
        ELSE '3+ hours'
    END                                                  AS delay_band,
    FALSE                                                AS coverage_complete   -- set in step 3
FROM derived;

ALTER TABLE analytics.movements ADD PRIMARY KEY (direction, flight_id);   -- D9
CREATE UNIQUE INDEX ON analytics.movements (movement_key);
CREATE INDEX ON analytics.movements (registration, actual_time);
CREATE INDEX ON analytics.movements (sched_time);
CREATE INDEX ON analytics.movements (sched_month, direction);
CREATE INDEX ON analytics.movements (airline_icao);
CREATE INDEX ON analytics.movements (station_iata);

-- ---------------------------------------------------------------------
-- 3. Monthly coverage: flag months where the export is incomplete.
--    Two failure modes exist in this export:
--      a) missing days   (Dec 2025 has 15 of 31 days)
--      b) thin days      (Mar to Aug 2026 have every day but only
--                         ~260 to 500 movements/day vs ~620 to 660 normally)
--    So the flag needs both tests. MIN_PER_DAY = 550 separates the two
--    groups cleanly; adjust it if you refresh the export.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.monthly_coverage;

CREATE TABLE analytics.monthly_coverage AS
WITH params AS (SELECT 550 AS min_per_day)
SELECT
    m.sched_month,
    m.direction,
    COUNT(*)                                             AS movements,
    COUNT(DISTINCT m.sched_date)                         AS days_present,
    EXTRACT(DAY FROM (m.sched_month + INTERVAL '1 month - 1 day'))::int AS days_in_month,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT m.sched_date), 0)          AS avg_per_day,
    (COUNT(DISTINCT m.sched_date) = EXTRACT(DAY FROM (m.sched_month + INTERVAL '1 month - 1 day'))::int
     AND COUNT(*)::numeric / COUNT(DISTINCT m.sched_date) >= p.min_per_day) AS coverage_complete
FROM analytics.movements m
CROSS JOIN params p
GROUP BY m.sched_month, m.direction, p.min_per_day
ORDER BY m.sched_month, m.direction;

ALTER TABLE analytics.monthly_coverage ADD PRIMARY KEY (sched_month, direction);

UPDATE analytics.movements m
SET    coverage_complete = c.coverage_complete
FROM   analytics.monthly_coverage c
WHERE  c.sched_month = m.sched_month
AND    c.direction   = m.direction;

-- ---------------------------------------------------------------------
-- 4. Validation queries
-- ---------------------------------------------------------------------

-- 4a. Row counts reconcile to staging
SELECT direction, COUNT(*) AS movements
FROM analytics.movements GROUP BY direction ORDER BY direction;

-- 4b. Headline OTP per direction (operated, non-outlier flights only)
SELECT direction,
       COUNT(*)                                          AS operated_flights,
       ROUND(AVG(delay_min), 1)                          AS avg_delay_min,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_min)::numeric, 1) AS median_delay_min,
       ROUND(100.0 * AVG(is_delayed_15::int), 1)         AS pct_delayed_15
FROM analytics.movements
WHERE is_operated AND NOT delay_outlier
GROUP BY direction ORDER BY direction;

-- 4c. Coverage table (this goes in the README as a limitation)
SELECT * FROM analytics.monthly_coverage ORDER BY sched_month, direction;

-- 4d. Airline name standardisation check: should be one name per code
SELECT airline_icao, airline_name, total_movements
FROM analytics.dim_airline ORDER BY total_movements DESC LIMIT 15;
