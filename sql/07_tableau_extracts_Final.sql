-- =====================================================================
-- 07_tableau_extracts.sql
-- Purpose : build the extract layer that Tableau Public reads.
--
-- Why CSV and not a live connection:
--   Tableau Desktop Public Edition cannot connect to PostgreSQL. It reads
--   files (CSV, Excel, JSON) and a few cloud sources only. So the database
--   stays the source of truth and this script emits flat files from it.
--   Anyone with full Tableau Desktop can skip the export and connect live
--   to the analytics schema instead.
--
-- Design: a small star schema rather than one wide table.
--   fct_movements  one row per flight, keys only, no descriptive strings
--   fct_turnarounds one row per aircraft turn
--   dim_airline / dim_station  the names, joined in Tableau
--   agg_*          three pre-aggregated tables backing specific charts
--                  whose binning must match the Python analysis exactly
--
-- Keeping names out of the fact tables cuts their size by roughly half and
-- demonstrates the modelling pattern a BI reviewer expects to see.
--
-- Run after 06_turnaround.sql. Export instructions at the bottom.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS extract;

-- ---------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.dim_airline;
CREATE TABLE extract.dim_airline AS
SELECT airline_icao,
       airline_iata,
       airline_name,
       carrier_group,
       total_movements
FROM analytics.dim_airline;

DROP TABLE IF EXISTS extract.dim_station;
CREATE TABLE extract.dim_station AS
SELECT station_iata,
       MODE() WITHIN GROUP (ORDER BY station_name) AS station_name,
       COUNT(*)                                    AS movements,
       COUNT(*) FILTER (WHERE direction = 'A')     AS arrivals,
       COUNT(*) FILTER (WHERE direction = 'D')     AS departures
FROM analytics.movements
WHERE station_iata IS NOT NULL
GROUP BY station_iata;

-- ---------------------------------------------------------------------
-- Fact: movements (one row per flight)
-- delay_min rounded to whole minutes; sub-minute precision is noise here
-- and the rounding materially shrinks the file.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.fct_movements;
CREATE TABLE extract.fct_movements AS
SELECT
    direction,
    sched_date,
    sched_month,
    sched_hour,
    sched_dow,
    sched_dow_name,
    airline_icao,
    aircraft_type,
    -- Terminals are emitted as T1/T2/T3/PT rather than 1/2/3/PT. Bare digits
    -- make BI tools type the column as numeric, which silently turns PT into
    -- NULL and drops ~8,200 movements. The prefix also labels better.
    CASE WHEN terminal ~ '^[0-9]+$' THEN 'T' || terminal ELSE terminal END AS terminal,
    station_iata,
    status_code,
    traffic_type_code,
    -- Booleans are exported as 1/0 integers, not PostgreSQL's native t/f.
    -- Tableau reads "t"/"f" as text, which silently breaks every SUM() on
    -- these columns. As integers they aggregate directly.
    is_operated::int      AS is_operated,
    is_cancelled::int     AS is_cancelled,
    ROUND(delay_min)::int AS delay_min,
    is_delayed_15::int    AS is_delayed_15,
    delay_band,
    ROUND(taxi_min)::int  AS taxi_min,
    taxi_outlier::int     AS taxi_outlier,
    coverage_complete::int AS coverage_complete
FROM analytics.movements
WHERE NOT delay_outlier OR delay_min IS NULL;

-- ---------------------------------------------------------------------
-- Fact: turnarounds (one row per aircraft turn)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.fct_turnarounds;
CREATE TABLE extract.fct_turnarounds AS
SELECT
    turn_date,
    arr_hour,
    arr_dow,
    airline_icao,
    carrier_group,
    aircraft_type,
    CASE WHEN arr_terminal ~ '^[0-9]+$' THEN 'T' || arr_terminal
         ELSE arr_terminal END         AS arr_terminal,
    CASE WHEN dep_terminal ~ '^[0-9]+$' THEN 'T' || dep_terminal
         ELSE dep_terminal END         AS dep_terminal,
    terminal_changed::int         AS terminal_changed,
    from_station,
    to_station,
    ROUND(sched_ground_min)::int  AS sched_ground_min,
    ROUND(actual_ground_min)::int AS actual_ground_min,
    ROUND(ground_variance)::int   AS ground_variance,
    ROUND(arr_delay_min)::int     AS arr_delay_min,
    ROUND(dep_delay_min)::int     AS dep_delay_min,
    ROUND(delay_recovered)::int   AS delay_recovered,
    arr_delayed_15::int           AS arr_delayed_15,
    dep_delayed_15::int           AS dep_delayed_15,
    is_propagated::int            AS is_propagated,
    turn_band,
    arr_delay_band,
    coverage_complete::int        AS coverage_complete
FROM analytics.turnarounds;

-- ---------------------------------------------------------------------
-- Aggregate 1: the cascade curve
-- Binning matches python/delay_cascade.py exactly so the dashboard and
-- the notebook cannot disagree.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.agg_cascade_curve;
CREATE TABLE extract.agg_cascade_curve AS
WITH binned AS (
    SELECT carrier_group,
           FLOOR(GREATEST(LEAST(arr_delay_min, 129), -30) / 10.0) * 10 AS bin_start,
           dep_delayed_15,
           dep_delay_min
    FROM analytics.turnarounds
    WHERE actual_ground_min < 360
)
SELECT carrier_group,
       bin_start::int                                  AS arr_delay_bin_start,
       (bin_start + 10)::int                           AS arr_delay_bin_end,
       COUNT(*)                                        AS turns,
       ROUND(100.0 * AVG(dep_delayed_15::int), 1)      AS pct_dep_delayed_15,
       ROUND(AVG(dep_delay_min), 1)                    AS avg_dep_delay_min
FROM binned
GROUP BY carrier_group, bin_start
HAVING COUNT(*) >= 200
ORDER BY carrier_group, bin_start;

-- ---------------------------------------------------------------------
-- Aggregate 2: buffer against recovery (late arrivals only)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.agg_buffer_recovery;
CREATE TABLE extract.agg_buffer_recovery AS
SELECT
    CASE
        WHEN sched_ground_min <  60 THEN '030-060'
        WHEN sched_ground_min <  90 THEN '060-090'
        WHEN sched_ground_min < 120 THEN '090-120'
        WHEN sched_ground_min < 150 THEN '120-150'
        WHEN sched_ground_min < 180 THEN '150-180'
        WHEN sched_ground_min < 240 THEN '180-240'
        ELSE                             '240-300'
    END                                             AS sched_ground_band,
    COUNT(*)                                        AS turns,
    ROUND(AVG(arr_delay_min), 1)                    AS avg_arr_delay_min,
    ROUND(AVG(dep_delay_min), 1)                    AS avg_dep_delay_min,
    ROUND(100.0 * AVG(dep_delayed_15::int), 1)      AS pct_dep_delayed_15,
    ROUND(AVG(delay_recovered), 1)                  AS avg_min_recovered,
    ROUND(100.0 * AVG(delay_recovered) / NULLIF(AVG(arr_delay_min), 0), 1) AS pct_recovered
FROM analytics.turnarounds
WHERE arr_delay_min > 15
  AND sched_ground_min BETWEEN 30 AND 300
  AND actual_ground_min < 360          -- must match delay_cascade.py
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Aggregate 3: delay origin decomposition by airline
-- Baseline  = departure delay rate after an ON-TIME arrival
-- Inherited = departure delay rate after a LATE arrival
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.agg_airline_decomposition;
CREATE TABLE extract.agg_airline_decomposition AS
WITH split AS (
    SELECT t.airline_icao,
           t.airline_name,
           t.carrier_group,
           (t.arr_delay_min > 15) AS after_late_arrival,
           t.dep_delayed_15
    FROM analytics.turnarounds t
    WHERE t.turn_band IN ('Quick (<90)', 'Standard (90-180)')
),
pivoted AS (
    SELECT airline_icao,
           airline_name,
           carrier_group,
           COUNT(*) FILTER (WHERE NOT after_late_arrival)                    AS turns_after_ontime,
           COUNT(*) FILTER (WHERE after_late_arrival)                        AS turns_after_late,
           ROUND(100.0 * AVG(dep_delayed_15::int)
                 FILTER (WHERE NOT after_late_arrival), 1)                   AS pct_delayed_baseline,
           ROUND(100.0 * AVG(dep_delayed_15::int)
                 FILTER (WHERE after_late_arrival), 1)                       AS pct_delayed_inherited
    FROM split
    GROUP BY 1, 2, 3
)
SELECT *,
       ROUND(pct_delayed_inherited - pct_delayed_baseline, 1) AS recovery_gap,
       CASE
           WHEN pct_delayed_baseline >= 25 THEN 'Ground process'
           WHEN pct_delayed_inherited - pct_delayed_baseline >= 55 THEN 'No schedule slack'
           ELSE 'Both controlled'
       END                                                    AS regime
FROM pivoted
WHERE turns_after_ontime >= 300
  AND turns_after_late   >= 100
ORDER BY pct_delayed_baseline DESC;

-- ---------------------------------------------------------------------
-- Aggregate 4: KPI tiles
-- One row, wide. Tableau reads it as the source for the headline numbers
-- so they are computed once in SQL rather than re-derived per sheet.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.agg_kpi;
CREATE TABLE extract.agg_kpi AS
SELECT
    (SELECT COUNT(*) FROM analytics.movements)                                          AS total_movements,
    (SELECT COUNT(*) FROM analytics.turnarounds)                                        AS total_turnarounds,
    (SELECT COUNT(DISTINCT airline_icao) FROM analytics.movements)                      AS airlines,
    (SELECT COUNT(DISTINCT station_iata) FROM analytics.movements)                      AS destinations,
    (SELECT ROUND(100.0 * AVG(is_delayed_15::int), 1) FROM analytics.movements
       WHERE direction = 'A' AND is_operated AND NOT delay_outlier)                     AS pct_arr_delayed_15,
    (SELECT ROUND(100.0 * AVG(is_delayed_15::int), 1) FROM analytics.movements
       WHERE direction = 'D' AND is_operated AND NOT delay_outlier)                     AS pct_dep_delayed_15,
    (SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_min)::numeric, 1)
       FROM analytics.movements
       WHERE direction = 'D' AND is_operated AND NOT delay_outlier)                     AS median_dep_delay_min,
    (SELECT ROUND(100.0 * AVG(is_cancelled::int), 2) FROM analytics.movements)          AS pct_cancelled,
    -- the < 360 filter matches delay_cascade.py so the dashboard and the
    -- notebook report the same medians
    (SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sched_ground_min)::numeric, 0)
       FROM analytics.turnarounds
       WHERE carrier_group = 'Home carrier' AND actual_ground_min < 360)                AS median_sched_ground_home,
    (SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sched_ground_min)::numeric, 0)
       FROM analytics.turnarounds
       WHERE carrier_group = 'Foreign carrier' AND actual_ground_min < 360)             AS median_sched_ground_foreign;

-- ---------------------------------------------------------------------
-- Aggregate 5: monthly coverage, for the data-quality note on the dashboard
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS extract.agg_coverage;
CREATE TABLE extract.agg_coverage AS
SELECT sched_month, direction, movements, days_present, days_in_month,
       avg_per_day, coverage_complete::int AS coverage_complete
FROM analytics.monthly_coverage
ORDER BY sched_month, direction;

-- ---------------------------------------------------------------------
-- Row counts
-- ---------------------------------------------------------------------
SELECT 'fct_movements'            AS tbl, COUNT(*) FROM extract.fct_movements
UNION ALL SELECT 'fct_turnarounds',           COUNT(*) FROM extract.fct_turnarounds
UNION ALL SELECT 'dim_airline',               COUNT(*) FROM extract.dim_airline
UNION ALL SELECT 'dim_station',               COUNT(*) FROM extract.dim_station
UNION ALL SELECT 'agg_cascade_curve',         COUNT(*) FROM extract.agg_cascade_curve
UNION ALL SELECT 'agg_buffer_recovery',       COUNT(*) FROM extract.agg_buffer_recovery
UNION ALL SELECT 'agg_airline_decomposition', COUNT(*) FROM extract.agg_airline_decomposition
UNION ALL SELECT 'agg_kpi',                   COUNT(*) FROM extract.agg_kpi
UNION ALL SELECT 'agg_coverage',              COUNT(*) FROM extract.agg_coverage;

-- =====================================================================
-- EXPORTING
--
-- Option A - psql (fastest, run from the dxb_ops folder):
--
   \copy extract.fct_movements             TO 'data/tableau/fct_movements.csv'             CSV HEADER
   \copy extract.fct_turnarounds           TO 'data/tableau/fct_turnarounds.csv'           CSV HEADER
--   \copy extract.dim_airline               TO 'data/tableau/dim_airline.csv'               CSV HEADER
--   \copy extract.dim_station               TO 'data/tableau/dim_station.csv'               CSV HEADER
--   \copy extract.agg_cascade_curve         TO 'data/tableau/agg_cascade_curve.csv'         CSV HEADER
--   \copy extract.agg_buffer_recovery       TO 'data/tableau/agg_buffer_recovery.csv'       CSV HEADER
--   \copy extract.agg_airline_decomposition TO 'data/tableau/agg_airline_decomposition.csv' CSV HEADER
--   \copy extract.agg_kpi                   TO 'data/tableau/agg_kpi.csv'                   CSV HEADER
--   \copy extract.agg_coverage              TO 'data/tableau/agg_coverage.csv'              CSV HEADER
--
-- Option B - pgAdmin:
--   right-click each table under Schemas > extract > Tables,
--   Import/Export Data > Export, Format csv, Header yes, Encoding UTF8.
--
-- Create data/tableau/ first. Add fct_*.csv to .gitignore (they are large
-- and regenerable); commit the dim_* and agg_* files, which are small.
-- =====================================================================
