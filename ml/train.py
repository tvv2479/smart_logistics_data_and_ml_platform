import logging
import numpy as np
import pandas as pd
from catboost import CatBoostRegressor, Pool
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from .features import CAT_FEATURES, NUM_FEATURES, FEATURES, TARGET

log = logging.getLogger(__name__)

def train_catboost(train_df: pd.DataFrame) -> CatBoostRegressor:
    """Обучение CatBoost."""
    model = CatBoostRegressor(
        iterations=800, learning_rate=0.05, depth=6,
        loss_function='RMSE', random_seed=42, verbose=100,
    )
    model.fit(train_df[FEATURES], train_df[TARGET], cat_features=CAT_FEATURES)
    return model

def train_ridge(train_df: pd.DataFrame) -> Pipeline:
    """Обучение Ridge (линейный бейзлайн для сравнения)."""
    pre = ColumnTransformer([
        ('cat', OneHotEncoder(handle_unknown='ignore'), CAT_FEATURES),
        ('num', StandardScaler(), NUM_FEATURES),
    ])
    model = Pipeline([('pre', pre), ('clf', Ridge(alpha=1.0, random_state=42))])
    model.fit(train_df[FEATURES], train_df[TARGET])
    return model

def predict_catboost(model: CatBoostRegressor, df: pd.DataFrame) -> np.ndarray:
    if len(df) == 0: return np.array([])
    return model.predict(Pool(df[FEATURES], cat_features=CAT_FEATURES))

def predict_ridge(model: Pipeline, df: pd.DataFrame) -> np.ndarray:
    if len(df) == 0: return np.array([])
    return model.predict(df[FEATURES])

def compute_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> dict:
    """Расчет R2, MAPE, RMSE, MAE."""
    mask = y_true > 0
    return {
        'r2':   float(r2_score(y_true, y_pred)),
        'rmse': float(np.sqrt(mean_squared_error(y_true, y_pred))),
        'mae':  float(mean_absolute_error(y_true, y_pred)),
        'mape': float(np.mean(np.abs((y_true[mask] - y_pred[mask]) / y_true[mask])) * 100),
    }