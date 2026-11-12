import argparse
import logging
import os
from datetime import date, timedelta

from .pipeline import run_etl


def _default_window() -> tuple[date, date]:
    as_of = date.fromisoformat(os.getenv("AS_OF_DATE", "2026-10-26"))
    # дефолт: 3 месяца + 3 недели до as_of (покрывает train+test для ML расчета)
    return as_of - timedelta(days=90), as_of


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    ds, de = _default_window()
    parser = argparse.ArgumentParser(
        description="ETL raw -> core (DQ + currency + categories)"
    )
    parser.add_argument("--start-date", default=ds.isoformat())
    parser.add_argument("--end-date",   default=de.isoformat())
    args = parser.parse_args()

    start = date.fromisoformat(args.start_date)
    end   = date.fromisoformat(args.end_date)
    logging.info("ETL start=%s end=%s", start, end)

    stats = run_etl(start, end)
    logging.info(
        "Done. read=%s loaded=%s quarantined=%s",
        stats["rows_read"], stats["rows_loaded"], stats["rows_quarantined"],
    )


if __name__ == "__main__":
    main()