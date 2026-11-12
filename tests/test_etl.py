import pytest
from datetime import date
from etl.pipeline import run_etl
from etl.db import get_conn

def test_idempotency():
    """Повторный запуск ETL не должен задваивать данные."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("select count(*), sum(price_rub) from core.prices_clean where loading_date >= '2026-10-01'")
            before = cur.fetchone()
            
    run_etl(date(2026, 10, 1), date(2026, 10, 26))
    
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("select count(*), sum(price_rub) from core.prices_clean where loading_date >= '2026-10-01'")
            after = cur.fetchone()
            
    assert before['count'] == after['count']
    assert before['sum'] == after['sum']

def test_dq_rules():
    """Проверка очистки данных."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("sekect count(*) as cnt from core.prices_clean where price_rub <= 0 or distance <= 0")
            assert cur.fetchone()['cnt'] == 0
            
            cur.execute("select count(*) as cnt from core.dq_quarantine_prices")
            assert cur.fetchone()['cnt'] > 0