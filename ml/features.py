import logging
from datetime import date
import numpy as np
import pandas as pd
import psycopg
from psycopg.rows import dict_row

log = logging.getLogger(__name__)

# Жесткие границы из задания
TRAIN_START = date(2026, 7, 26)
TRAIN_END   = date(2026, 10, 5)   # не включительно
TEST_START  = date(2026, 10, 5)   # включительно
TEST_END    = date(2026, 10, 26)  # включительно

CAT_FEATURES = [
    'loading_city', 'unloading_city', 'loading_region', 'unloading_region',
    'body_group', 'weight_category', 'volume_category',
]
NUM_FEATURES = [
    'distance', 'total_weight', 'total_volume',
    'loading_lat', 'loading_lon', 'unloading_lat', 'unloading_lon',
    'year', 'doy_sin', 'doy_cos', 'month_sin', 'month_cos', 'dow_sin', 'dow_cos',
]
FEATURES = CAT_FEATURES + NUM_FEATURES
TARGET   = 'price_rub'

FEATURE_SQL = """
with body_grouped as (
select distinct
       p.price_id,
       coalesce(bg_pbt.body_group, bg_bt.body_group, 'Не указан') as body_group
  from core.prices_clean p
  left join price_body_types pbt on pbt.price_id    = p.price_id
  left join mart.dim_body_group bg_pbt on bg_pbt.body_type_id = pbt.body_type_id
  left join mart.dim_body_group bg_bt on bg_bt.body_type_id  = p.body_type
       )
       select p.price_id, 
              p.loading_date, 
              p.loading_city_gcid, 
              p.unloading_city_gcid,
              cf.city as loading_city, 
              cf.region as loading_region,
              cf.latitude as loading_lat, 
              cf.longitude as loading_lon,
              ct.city as unloading_city, 
              ct.region as unloading_region,
              ct.latitude as unloading_lat, 
              ct.longitude as unloading_lon,
              p.distance, 
              p.total_weight, 
              p.total_volume,
              bg.body_group, 
              p.weight_category, 
              p.volume_category,
              extract(year from p.loading_date)::int as year,
              extract(doy from p.loading_date)::int as doy,
              extract(month from p.loading_date)::int as month_num,
              extract(ISODOW from p.loading_date)::int as dow,
              p.price_rub
         from core.prices_clean p
         join mart.dim_cities_dedup cf on cf.gc_id = p.loading_city_gcid
         join mart.dim_cities_dedup ct on ct.gc_id = p.unloading_city_gcid
         left join body_grouped bg on bg.price_id = p.price_id
        where p.is_fact = TRUE 
          and p.complex = FALSE 
          and p.outlier_mark = FALSE
          and p.price_rub > 0 AND p.distance > 0
          and p.loading_date >= %(start)s
"""

def load_features(dsn: str, start_date: date = TRAIN_START) -> pd.DataFrame:
    """Загружает данные из БД."""
    with psycopg.connect(dsn, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(FEATURE_SQL, {'start': start_date})
            rows = cur.fetchall()
    df = pd.DataFrame(rows)
    log.info("Загружено %d строк из core.prices_clean", len(df))
    return add_cyclical(df)

def add_cyclical(df: pd.DataFrame) -> pd.DataFrame:
    """Добавляет sin/cos признаки для дат."""
    df = df.copy()
    # Циклическое кодирование (день года, месяц, день недели)
    df['doy_sin']   = np.sin(2 * np.pi * df['doy'] / 365.25)
    df['doy_cos']   = np.cos(2 * np.pi * df['doy'] / 365.25)
    df['month_sin'] = np.sin(2 * np.pi * df['month_num'] / 12.0)
    df['month_cos'] = np.cos(2 * np.pi * df['month_num'] / 12.0)
    df['dow_sin']   = np.sin(2 * np.pi * df['dow'] / 7.0)
    df['dow_cos']   = np.cos(2 * np.pi * df['dow'] / 7.0)

    # Очистка от NaN
    for c in NUM_FEATURES:
        df[c] = pd.to_numeric(df[c], errors='coerce').fillna(0.0)
    for c in CAT_FEATURES:
        df[c] = df[c].fillna('NA').astype(str)
    return df

def split(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Делит выборку строго по времени (без shuffle)."""
    d = pd.to_datetime(df['loading_date']).dt.date
    train  = df[(d >= TRAIN_START) & (d <  TRAIN_END)].copy()
    test   = df[(d >= TEST_START)  & (d <= TEST_END)].copy()
    future = df[d >  TEST_END].copy()
    log.info("Разбиение: train=%d, test=%d, future=%d", len(train), len(test), len(future))
    return train, test, future