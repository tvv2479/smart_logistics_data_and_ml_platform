from contextlib import contextmanager
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

from .config import Config

_cfg = Config()


@contextmanager
def get_conn():
    """Соединение с autocommit=False, управление транзакцией явно."""
    with psycopg.connect(_cfg.dsn, row_factory=dict_row, autocommit=False) as conn:
        yield conn


def read_sql(rel_path: str) -> str:
    """Читает SQL относительно корня проекта."""
    root = Path(__file__).resolve().parent.parent
    return (root / rel_path).read_text(encoding="utf-8")