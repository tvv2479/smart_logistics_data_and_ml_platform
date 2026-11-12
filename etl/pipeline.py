import logging
from datetime import date, timedelta

from .db import get_conn, read_sql

log = logging.getLogger(__name__)

SQL_PATH = "etl/sql/dq_pipeline.sql"


def run_etl(start_date: date, end_date: date) -> dict:
    """
    Прогоняет ETL за окно [start_date, end_date] включительно.
    Идемпотентно: партиции по loading_date перезаписываются в транзакции.
    """
    if start_date > end_date:
        raise ValueError(f"start_date {start_date} > end_date {end_date}")

    end_plus_1 = end_date + timedelta(days=1)
    sql = read_sql(SQL_PATH)

    with get_conn() as conn:
        with conn.cursor() as cur:
            # 1. Журнал: начало
            cur.execute(
                """
                insert into core.etl_run_log
                          (start_date, end_date, stage, status)
                          values (%s, %s, 'etl_cleansing', 'running')
                          returning run_id
                """,
                (start_date, end_date),
            )
            run_id = cur.fetchone()["run_id"]
            conn.commit()
            log.info("ETL run %s started: %s .. %s", run_id, start_date, end_date)

            try:
                # 2. Основной SQL
                sql_text = (
                    sql
                    .replace("%(start)s",      f"DATE '{start_date.isoformat()}'")
                    .replace("%(end_plus_1)s", f"DATE '{end_plus_1.isoformat()}'")
                )
                cur.execute(sql_text)

                # psycopg3 в simple protocol после multi-statement стоит на ПЕРВОМ result set.
                # Идёт по всем и берёт тот, у которого есть колонка rows_read.
                stats: dict = {}
                while True:
                    if cur.description is not None:
                        row = cur.fetchone()
                        if row and "rows_read" in row:
                            stats = row
                    if not cur.nextset():
                        break

                if not stats:
                    raise RuntimeError(
                        "ETL SQL did not return rows_read/rows_loaded/rows_quarantined"
                    )

                cur.execute(
                    """
                    update core.etl_run_log
                       set status='success',
                           rows_read=%s,
                           rows_loaded=%s,
                           rows_quarantined=%s,
                           finished_at=now()
                     where run_id=%s
                     """,
                    (stats["rows_read"], stats["rows_loaded"],
                    stats["rows_quarantined"], run_id),
                )
                conn.commit()
                log.info("ETL run %s OK: %s", run_id, stats)
                return {**stats, "run_id": run_id}

            except Exception as exc:
                conn.rollback()
                # откат SQL мог откатить и лог. Пишем в отдельной транзакции
                with conn.cursor() as cur2:
                    cur2.execute(
                        """UPDATE core.etl_run_log
                              SET status='failed', error=%s, finished_at=now()
                            WHERE run_id=%s""",
                        (str(exc)[:2000], run_id),
                    )
                    conn.commit()
                log.exception("ETL run %s failed", run_id)
                raise