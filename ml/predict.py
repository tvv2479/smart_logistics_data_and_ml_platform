import logging
from typing import Optional
import numpy as np
import pandas as pd
import psycopg

log = logging.getLogger(__name__)

def save_predictions(
    dsn: str, model_name: str,
    test_df: pd.DataFrame, test_pred: np.ndarray,
    future_df: pd.DataFrame, future_pred: np.ndarray,
) -> None:
    """Сохраняет предсказания в mart.ml_price_predictions."""
    rows = []
    
    def _append(df, pred, is_future):
        for (_, r), p in zip(df.iterrows(), pred):
            actual = None if is_future else float(r['price_rub'])
            pred_f = float(p)
            
            if is_future:
                abs_err, ape = None, None
            else:
                abs_err = abs(actual - pred_f)
                ape = abs_err / actual * 100.0 if actual > 0 else None
                
            rows.append((
                int(r['price_id']), r['loading_date'],
                int(r['loading_city_gcid']), int(r['unloading_city_gcid']),
                str(r['body_group']), actual, pred_f, abs_err, ape, model_name,
            ))

    _append(test_df, test_pred, False)   # Факт + Прогноз
    _append(future_df, future_pred, True) # Только прогноз (факта нет)

    if not rows:
        return

    insert_sql = """
    insert into mart.ml_price_predictions
           (price_id, loading_date, loading_city_gcid, unloading_city_gcid,
            body_group, actual_price_rub, predicted_price_rub,
            abs_error_rub, ape_pct, model_name)
    values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
    """
    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            # Идемпотентность: удаляем старые результаты этой модели
            cur.execute("delete from mart.ml_price_predictions where model_name = %s", (model_name,))
            cur.executemany(insert_sql, rows)
        conn.commit()
    log.info("Сохранено %d прогнозов для модели '%s'", len(rows), model_name)