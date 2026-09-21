# Delay Propagation at Dubai International (DXB)

***How much of an arrival delay does the next flight inherit, and what stops it?***

An end-to-end analysis of 510,000 flight movements at DXB, built in PostgreSQL
and Python: *raw CSV → cleaned database → regression → dashboard*.

---

## The business question

When an aircraft lands late at Dubai International, the delay does not stop
there. The same airframe turns around and flies out again, often within the
hour. An operations team needs to know three things:

1. How much of the arrival delay *survives* the turnaround?
2. How much scheduled ground time is *enough* to absorb it?
3. When a flight leaves late, was the delay **inherited** from the inbound
   aircraft, or **created** on the ground at DXB?

---

## The data

| | |
|---|---|
| **Source** | Dubai Airports flight information *(arrivals and departures)* |
| **Period** | Flights scheduled 1 May 2025 to 12 September 2026 |
| **Volume** | 509,382 movements after cleaning; 230,928 aircraft turnarounds |
| **Coverage** | 158 airlines, 83 aircraft types, 3,800 individual airframes |
| **Fields** | Scheduled, estimated and actual times; airline; route; terminal; stand; gate; baggage belt; aircraft registration; status |
| **Licence** | Open data |

> **What the data does not contain:** delay cause codes, weather, passenger
> numbers, crew or load information. *This shapes every conclusion below.*

---

## Tools

**PostgreSQL 16** and **pgAdmin** for storage and transformation · **Python**
*(pandas, statsmodels, matplotlib)* in **VS Code** for analysis · **Tableau
Public** and **Power BI** for dashboards · **Git** for version control.

---

## How it was built

A three-layer database, each layer a separate SQL script so every decision is
visible and reviewable:

```text
raw        → exact copy of the source CSVs, every column stored as text
staging    → typed, de-duplicated, cleaned; one row per flight
analytics  → movements, turnarounds, airline dimension, coverage flags
```

**Run order:** `01_schemas_and_raw.sql` → *import both CSVs* →
`03_staging_arrivals.sql` → `04_staging_departures.sql` → `05_movements.sql` →
`06_turnaround.sql` → *the Python notebook*.

### The turnaround join

*The core of the analysis.* Every movement is ordered by aircraft registration
and actual block time, then a window function pairs each arrival with the next
movement of that same airframe. Where that next movement is a departure and the
ground time falls between 20 minutes and 24 hours, it is a valid turnaround.

**95.3% of arrivals pair cleanly.** The remainder is accounted for: *2.7%*
exceeded 24 hours on the ground, *1.4%* were followed by another arrival
because the departure is missing from the export, *0.5%* were delay outliers,
*0.1%* were the last record for that airframe.

### Cleaning decisions

*Every one of these is documented in the SQL where it happens.*

- **Duplicate snapshots** — 531 flights appear twice with different load
  timestamps as their status changed. *The latest snapshot wins.*
- **Terminal values** — stored as both `'3'` and `'3 '`, which made three
  terminals look like six. *Trimmed.*
- **Airline names** — *"Flydubai"* and *"Fly dubai"* are the same carrier. A
  dimension table takes the most frequent name per ICAO code, collapsing the
  raw names to 158 standardised carriers *without hard-coding special cases*.
- **Flight IDs are not unique across files** — 83 IDs appear in both exports
  attached to unrelated flights. *The movements table is keyed on direction
  plus flight ID.*
- **Missing take-off times** — absent for *56%* of departures, so off-block
  time is the authoritative departure timestamp and take-off is used only for
  taxi analysis.
- **Codeshares** — stored tab-separated in a single cell; *split into an array*.
- **Outliers** — delays outside `-60` to `+600` minutes are flagged and
  excluded from averages. *Almost always date-roll artefacts.*

### Metric definitions

| Metric | Definition |
|---|---|
| **Delay** | Actual minus scheduled ***block*** time *(in-block for arrivals, off-block for departures)* |
| **Delayed** | More than 15 minutes late — *the standard industry threshold* |
| **Ground time** | Actual departure block time minus actual arrival block time |
| **Pass-through** | Minutes of departure delay generated *per minute* of arrival delay |
| **Baseline delay rate** | Share of departures 15+ late ***after an on-time arrival***, so the inbound contribution is zero |

---

## Key findings

**1. Departure delay is the bigger problem.** *32.9%* of departures leave 15 or
more minutes late against *23.7%* of arrivals. The median departure is 8.6
minutes late; the median arrival is 1.8 minutes *early*.

**2. A minute of arrival delay becomes 0.65 minutes of departure delay** after
controlling for scheduled ground time, carrier, time of day and terminal
changes. *Each additional hour of scheduled ground time absorbs 4.2 minutes.*

**3. That single figure hides two different airports.** Foreign carriers pass
through **0.93** minutes per minute — *almost all of it*. Emirates and Flydubai
pass through **0.27**. The cause is schedule design: home carriers plan a
median *150 minutes* on the ground, foreign carriers *70*.

**4. Buffer works, up to a point.** After a late arrival, departures with 60–90
minutes of scheduled ground time are late *90%* of the time. At 120–150 minutes
that falls to *50%*. Past 180 minutes it settles at *40%* and stops improving —
*that floor is delay generated at DXB rather than inherited.*

**5. Airlines fail in three distinct ways.** Splitting each carrier's delay
rate by the state of the inbound aircraft separates them:

| Pattern | Example | After on-time arrival | After late arrival |
|---|---|---|---|
| *Ground process* | SpiceJet | **27.4%** | 95.5% |
| *No schedule slack* | Kuwait Airways | **9.9%** | 89.8% |
| *Both controlled* | Saudia | **6.2%** | 37.8% |
| *Buffered hub* | Emirates | **23.0%** | 47.6% |

***Three problems needing three different responses.***

---

## Recommendations

**Set a minimum ground time of 120 minutes for turns exposed to long-haul
inbound delay.** The recovery curve is steep to that point and flat after 180,
so *the first extra hour buys most of the benefit at the lowest schedule cost*.

**Separate the two delay problems before trying to fix either.** Carriers with
a high *baseline* rate need ground-process attention; carriers with a low
baseline but a large *gap* need schedule slack. *Treating them the same wastes
effort on both.*

**Target the 40% floor with ground operations, not scheduling.** No amount of
buffer moves it, which means it is stand allocation, crew, cargo or handling —
*none of which this data can separate, and all of which the airport can
measure*.

---

## Dashboards

> *Screenshots and live links to be added.*

---

## Limitations

**No delay causes.** The data records *that* a flight was late, not *why*.
Weather, air traffic control, crew and cargo are invisible. *"Created at DXB"
in this analysis means "not inherited from the inbound aircraft" — **not** "the
airline's fault".*

**Coverage gaps.** The export is incomplete in *two different ways*. December
2025 is missing half its days. March–August 2026 have every calendar day
present but only 260–500 movements a day against a normal 620–660. Seven months
*(May–November 2025)* pass both tests and carry a `coverage_complete` flag.
**Per-flight rates are unaffected; volume counts and trends are only valid with
that filter applied.** *37.9% of turnarounds fall in incomplete months.*

**Average, not extreme.** The regression estimates a *conditional mean* over a
heavy-tailed distribution, so it describes a typical turn rather than the
disruption days that matter most operationally.

**Towed aircraft.** 19,020 turns change terminal between arrival and departure,
inflating measured ground time relative to the productive part of the turn.
*Flagged in the data, not separately modelled.*

---

## What I would do next

1. **Join hourly weather for OMDB** — *the single largest missing variable*,
   and it would separate weather delay from process delay.
2. **Quantile regression at the 75th and 90th percentiles** — to describe the
   disruption cases the mean understates.
3. **Stand and gate utilisation** — using the parking position and gate fields
   that are *already in the data but unused here*.

---

## What went wrong, and what I changed

Partway through the build, the turnaround table came back **empty**. The cause
was run order: the movements table had been created *before* the arrivals were
staged, so it contained only departures — *and a turnaround needs both*.
Nothing failed loudly; the union simply produced half a dataset and every
downstream step accepted it.

The fix was a guard at the top of `05_movements.sql` that raises an exception
if either staging table is empty. ***A pipeline that fails silently is worse
than one that crashes***, and the check costs four lines.

---

## Running it yourself

```bash
git clone <https://github.com/marzrodie/Dubai_Airport_Operations>
cd dxb_ops
conda activate dxb_ops          # the Python environment
cp .env.example .env            # then edit with your PostgreSQL password
python -m pip install -r requirements.txt
python python/db.py             # connection check
```

Create a PostgreSQL database named `dxb_ops` *(the environment and the database
share a name; they are unrelated)*, then run the SQL scripts in the order
listed above. **In pgAdmin's Query Tool, make sure no text is selected before
running a script** — *it executes only the selection if there is one*.

Notebooks under `notebooks/` are paired with the scripts in `python/` via
**jupytext**. Edit either; run `python -m jupytext --sync` before committing.

```text
dxb_ops/
├── sql/          01, 03–06: schema, staging, analytics, turnarounds
├── python/       db.py (connection), delay_cascade.py (analysis)
├── notebooks/    paired .ipynb with saved outputs
├── reports/      figures and the one-page insight summary
└── data/         processed outputs (raw data is git-ignored)
```