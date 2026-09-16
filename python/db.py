"""
db.py - single place that knows how to talk to the dxb_ops database.

Every analysis script does:

    from db import get_engine, read_sql
    df = read_sql("SELECT * FROM analytics.turnarounds")

Connection details live in a .env file next to this project (see
.env.example). Nothing here should ever contain a password.
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIG_DIR = PROJECT_ROOT / "reports" / "figures"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

_engine: Engine | None = None


def get_engine() -> Engine:
    """Return a cached SQLAlchemy engine built from DXB_DB_URL in .env."""
    global _engine
    if _engine is None:
        load_dotenv(PROJECT_ROOT / ".env")
        url = os.getenv("DXB_DB_URL")
        if not url:
            raise RuntimeError(
                "DXB_DB_URL is not set. Copy .env.example to .env and fill it in."
            )
        _engine = create_engine(url, pool_pre_ping=True)
    return _engine


def read_sql(sql: str, **params) -> pd.DataFrame:
    """Run a query and return a DataFrame. Use :name placeholders for params."""
    with get_engine().connect() as conn:
        return pd.read_sql(text(sql), conn, params=params or None)


def ping() -> None:
    """Quick connectivity check; prints the row count of the analytics tables."""
    df = read_sql(
        """
        SELECT 'movements'   AS table_name, COUNT(*) AS rows FROM analytics.movements
        UNION ALL
        SELECT 'turnarounds', COUNT(*) FROM analytics.turnarounds
        UNION ALL
        SELECT 'dim_airline', COUNT(*) FROM analytics.dim_airline
        """
    )
    print(df.to_string(index=False))


if __name__ == "__main__":
    ping()
