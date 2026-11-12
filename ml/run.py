import logging
from datetime import datetime
from pathlib import Path
from etl.config import Config
from datetime import datetime, timezone
from .features import load_features, split
from .train import train_catboost, predict_catboost, train_ridge, predict_ridge, compute_metrics
from .predict import save_predictions

def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    log = logging.getLogger("ml")
    cfg = Config()

    # 1. Загрузка и разбиение
    df = load_features(cfg.dsn)
    train, test, future = split(df)

    # 2. Обучение CatBoost
    log.info("Обучение CatBoost...")
    cb = train_catboost(train)
    y_pred_test_cb = predict_catboost(cb, test)
    
    # 3. Метрики CatBoost
    m_cb = compute_metrics(test['price_rub'].to_numpy(), y_pred_test_cb)
    log.info("CatBoost TEST: R²=%.4f MAPE=%.2f%% RMSE=%.2f MAE=%.2f", 
             m_cb['r2'], m_cb['mape'], m_cb['rmse'], m_cb['mae'])

    # 4. Обучение Ridge (для сравнения)
    log.info("Обучение Ridge (бейзлайн)...")
    ridge = train_ridge(train)
    y_pred_test_ridge = predict_ridge(ridge, test)
    m_ridge = compute_metrics(test['price_rub'].to_numpy(), y_pred_test_ridge)
    log.info("Ridge    TEST: R²=%.4f MAPE=%.2f%% RMSE=%.2f MAE=%.2f", 
             m_ridge['r2'], m_ridge['mape'], m_ridge['rmse'], m_ridge['mae'])

    # 5. Сохранение модели и прогнозов
    Path("models").mkdir(exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    cb.save_model(f"models/catboost_{ts}.cbm")

    y_pred_future_cb = predict_catboost(cb, future)
    save_predictions(
        cfg.dsn, model_name=f"catboost_{ts}",
        test_df=test, test_pred=y_pred_test_cb,
        future_df=future, future_pred=y_pred_future_cb,
    )

if __name__ == "__main__":
    main()