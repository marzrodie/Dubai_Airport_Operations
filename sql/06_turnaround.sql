-- =====================================================================
-- 06_turnaround.sql
-- Purpose : pair each arrival with the next departure of the same aircraft
--           (registration) to measure ground time and delay propagation.
--
-- Method
--   1. Take every operated movement with a registration and an actual
--      block time, order them per registration by actual_time.
--   2. LEAD() gives the next movement of that aircraft. A valid turn is
--      an arrival whose next movement is a departure, with a ground time
--      inside a plausible window.
--   3. Anything else (A followed by A, D followed by D) is a gap in the
--      export, not a turn; counted in the validation section so the
--      limitation is quantified in the README.
--
-- Metric definitions (copy into the README):
--   sched_ground_min   scheduled off-block minus scheduled in-block
--   actual_ground_min  actual off-block minus actual in-block
--   ground_variance    actual minus scheduled ground time (negative = turn
--                      completed faster than planned)
--   arr_delay_min      arrival delay inherited from analytics.movements
--   dep_delay_min      delay of the departure that followed
--   delay_recovered    arr_delay_min minus dep_delay_min; positive means
--                      the ground crew clawed back minutes
--   is_propagated      arrival was >15 late AND the departure was >15 late
--   turn_band          Quick <90 min, Standard 90-180, Long 180-360,
--                      Overnight 360+ (all within the 24 h window)
--
-- Cleaning decisions:
--   D10 Window for a valid turn: 20 minutes to 24 hours. Under 20 min is
--       physically implausible and almost always a timestamp error;
--       over 24 h is parked, not turning. Both excluded, counts reported.
--   D11 Arrival delay outliers (see 05_movements) are excluded so the
--       cascade analysis is not driven by date-roll artefacts.
--   D12 A terminal change between arrival and departure (aircraft towed)
--       is kept but flagged, since it inflates ground time legitimately.
-- =====================================================================

DROP TABLE IF EXISTS analytics.turnarounds;

CREATE TABLE analytics.turnarounds AS
WITH stream AS (
    SELECT
        movement_key,
        flight_id,
        direction,
        registration,
        airline_icao,
        airline_name,
        carrier_group,
        aircraft_type,
        terminal,
        stand,
        station_iata,
        station_name,
        sched_time,
        actual_time,
        delay_min,
        delay_outlier,
        is_delayed_15,
        coverage_complete,
        LEAD(movement_key)  OVER w AS next_key,
        LEAD(direction)     OVER w AS next_direction,
        LEAD(airline_icao)  OVER w AS next_airline_icao,
        LEAD(terminal)      OVER w AS next_terminal,
        LEAD(stand)         OVER w AS next_stand,
        LEAD(station_iata)  OVER w AS next_station_iata,
        LEAD(station_name)  OVER w AS next_station_name,
        LEAD(sched_time)    OVER w AS next_sched_time,
        LEAD(actual_time)   OVER w AS next_actual_time,
        LEAD(delay_min)     OVER w AS next_delay_min,
        LEAD(delay_outlier) OVER w AS next_delay_outlier,
        LEAD(is_delayed_15) OVER w AS next_is_delayed_15
    FROM analytics.movements
    WHERE registration IS NOT NULL
      AND actual_time  IS NOT NULL
      AND is_operated
    WINDOW w AS (PARTITION BY registration ORDER BY actual_time, direction)
),
turns AS (
    SELECT
        s.movement_key                                    AS arr_key,
        s.next_key                                        AS dep_key,
        s.registration,
        s.aircraft_type,
        s.airline_icao,
        s.airline_name,
        s.carrier_group,
        (s.airline_icao IS DISTINCT FROM s.next_airline_icao) AS airline_changed,
        s.terminal                                        AS arr_terminal,
        s.next_terminal                                   AS dep_terminal,
        (s.terminal IS DISTINCT FROM s.next_terminal)     AS terminal_changed,   -- D12
        s.stand                                           AS arr_stand,
        s.next_stand                                      AS dep_stand,
        s.station_iata                                    AS from_station,
        s.station_name                                    AS from_station_name,
        s.next_station_iata                               AS to_station,
        s.next_station_name                               AS to_station_name,
        s.sched_time                                      AS arr_sched_time,
        s.actual_time                                     AS arr_actual_time,
        s.next_sched_time                                 AS dep_sched_time,
        s.next_actual_time                                AS dep_actual_time,
        s.actual_time::date                               AS turn_date,
        EXTRACT(HOUR FROM s.actual_time)::int             AS arr_hour,
        EXTRACT(ISODOW FROM s.actual_time)::int           AS arr_dow,
        ROUND(EXTRACT(EPOCH FROM (s.next_sched_time  - s.sched_time))  / 60.0, 1) AS sched_ground_min,
        ROUND(EXTRACT(EPOCH FROM (s.next_actual_time - s.actual_time)) / 60.0, 1) AS actual_ground_min,
        s.delay_min                                       AS arr_delay_min,
        s.next_delay_min                                  AS dep_delay_min,
        s.is_delayed_15                                   AS arr_delayed_15,
        s.next_is_delayed_15                              AS dep_delayed_15,
        s.coverage_complete
    FROM stream s
    WHERE s.direction = 'A'
      AND s.next_direction = 'D'
      AND NOT s.delay_outlier                                              -- D11
      AND NOT s.next_delay_outlier
      AND s.next_actual_time - s.actual_time BETWEEN INTERVAL '20 minutes'
                                              AND INTERVAL '24 hours'     -- D10
)
SELECT
    t.*,
    ROUND(actual_ground_min - sched_ground_min, 1)        AS ground_variance,
    ROUND(arr_delay_min - dep_delay_min, 1)               AS delay_recovered,
    (arr_delayed_15 AND dep_delayed_15)                   AS is_propagated,
    CASE
        WHEN actual_ground_min <  90  THEN 'Quick (<90)'
        WHEN actual_ground_min <  180 THEN 'Standard (90-180)'
        WHEN actual_ground_min <  360 THEN 'Long (180-360)'
        ELSE                               'Overnight (360+)'
    END                                                   AS turn_band,
    CASE
        WHEN arr_delay_min <= 0   THEN '0 On time or early'
        WHEN arr_delay_min <= 15  THEN '1 to 15 min'
        WHEN arr_delay_min <= 30  THEN '16 to 30 min'
        WHEN arr_delay_min <= 60  THEN '31 to 60 min'
        ELSE                           '60+ min'
    END                                                   AS arr_delay_band
FROM turns t;

ALTER TABLE analytics.turnarounds ADD PRIMARY KEY (arr_key);
CREATE UNIQUE INDEX ON analytics.turnarounds (dep_key);
CREATE INDEX ON analytics.turnarounds (registration, arr_actual_time);
CREATE INDEX ON analytics.turnarounds (airline_icao, aircraft_type);
CREATE INDEX ON analytics.turnarounds (turn_date);

-- ---------------------------------------------------------------------
-- Validation and first findings
-- ---------------------------------------------------------------------

-- V1. How many arrivals became a valid turn, and what happened to the rest
WITH stream AS (
    SELECT direction, delay_outlier, actual_time,
           LEAD(direction)     OVER w AS next_direction,
           LEAD(delay_outlier) OVER w AS next_delay_outlier,
           LEAD(actual_time)   OVER w AS next_actual_time
    FROM analytics.movements
    WHERE registration IS NOT NULL AND actual_time IS NOT NULL AND is_operated
    WINDOW w AS (PARTITION BY registration ORDER BY actual_time, direction)
)
SELECT
    CASE
        WHEN next_direction IS NULL                         THEN 'Last movement in export'
        WHEN next_direction = 'A'                           THEN 'Next is another arrival (departure missing)'
        WHEN delay_outlier OR next_delay_outlier            THEN 'Delay outlier excluded (D11)'
        WHEN next_actual_time - actual_time < INTERVAL '20 minutes' THEN 'Ground time < 20 min (D10)'
        WHEN next_actual_time - actual_time > INTERVAL '24 hours'   THEN 'Ground time > 24 h (D10)'
        ELSE 'Valid turn'
    END AS outcome,
    COUNT(*)                                                            AS arrivals,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                  AS pct
FROM stream
WHERE direction = 'A'
GROUP BY 1 ORDER BY 2 DESC;

-- V2. Ground time by carrier group and turn band
SELECT carrier_group, turn_band,
       COUNT(*)                                                         AS turns,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY actual_ground_min)::numeric, 0) AS median_ground_min,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sched_ground_min)::numeric, 0)  AS median_sched_min
FROM analytics.turnarounds
GROUP BY 1, 2 ORDER BY 1, 2;

-- V3. Quick-turn performance by airline and aircraft type (top volume)
SELECT airline_name, aircraft_type,
       COUNT(*)                                                         AS turns,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY actual_ground_min)::numeric, 0) AS median_ground_min,
       ROUND(100.0 * AVG(dep_delayed_15::int), 1)                       AS pct_dep_delayed
FROM analytics.turnarounds
WHERE turn_band = 'Quick (<90)'
GROUP BY 1, 2
HAVING COUNT(*) >= 500
ORDER BY turns DESC LIMIT 15;

-- V4. The cascade: does a late arrival become a late departure?
SELECT arr_delay_band,
       COUNT(*)                                                         AS turns,
       ROUND(100.0 * AVG(dep_delayed_15::int), 1)                       AS pct_dep_delayed_15,
       ROUND(AVG(dep_delay_min), 1)                                     AS avg_dep_delay_min,
       ROUND(AVG(delay_recovered), 1)                                   AS avg_min_recovered
FROM analytics.turnarounds
WHERE turn_band IN ('Quick (<90)', 'Standard (90-180)')
GROUP BY 1 ORDER BY 1;

-- V5. Data-quality flags to report
SELECT
    COUNT(*)                                        AS turns,
    COUNT(*) FILTER (WHERE terminal_changed)        AS towed_between_terminals,
    COUNT(*) FILTER (WHERE airline_changed)         AS airline_changed,
    COUNT(*) FILTER (WHERE NOT coverage_complete)   AS in_incomplete_months
FROM analytics.turnarounds;
