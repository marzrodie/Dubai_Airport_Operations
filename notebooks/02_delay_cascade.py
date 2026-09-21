# ---
# jupyter:
#   jupytext:
#     formats: ipynb,py:percent
#     text_representation:
#       extension: .py
#       format_name: percent
#       format_version: '1.3'
#       jupytext_version: 1.19.5
#   kernelspec:
#     display_name: python_project
#     language: python
#     name: python3
# ---

# %%
import sys
sys.path.append("../python")
from db import read_sql, FIG_DIR, PROCESSED_DIR

# %%
from __future__ import annotations

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import statsmodels.formula.api as smf

from db import FIG_DIR, PROCESSED_DIR, read_sql

FIG_DIR.mkdir(parents=True, exist_ok=True)
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

plt.rcParams.update({"figure.dpi": 110, "axes.spines.top": False, "axes.spines.right": False})


# %%
turns = read_sql(
    """
    SELECT arr_key, dep_key, registration, aircraft_type,
           airline_icao, airline_name, carrier_group,
           terminal_changed, arr_hour, arr_dow, turn_date,
           sched_ground_min, actual_ground_min, ground_variance,
           arr_delay_min, dep_delay_min, delay_recovered,
           arr_delayed_15, dep_delayed_15, is_propagated,
           turn_band, arr_delay_band, coverage_complete
    FROM analytics.turnarounds
    WHERE actual_ground_min < 360
    """
)
# Postgres NUMERIC columns can arrive as Python Decimal objects depending on
# the driver; force them to float so the filters and the regression behave.
num_cols = ["sched_ground_min", "actual_ground_min", "ground_variance",
            "arr_delay_min", "dep_delay_min", "delay_recovered"]
turns[num_cols] = turns[num_cols].apply(pd.to_numeric)
turns["arr_hour"] = pd.to_numeric(turns["arr_hour"]).astype(int)

if turns.empty:
    raise RuntimeError(
        "analytics.turnarounds returned 0 rows. Check the table exists in pgAdmin "
        "(SELECT COUNT(*) FROM analytics.turnarounds) and that .env points at the same database."
    )
print(f"{len(turns):,} turns under 6 hours loaded")
print(turns[["sched_ground_min", "actual_ground_min", "arr_delay_min", "dep_delay_min"]].describe().round(1))

