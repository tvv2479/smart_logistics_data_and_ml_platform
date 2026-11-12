
CREATE SCHEMA IF NOT EXISTS mart;

DROP TABLE IF EXISTS mart.ml_price_predictions;

CREATE TABLE mart.ml_price_predictions (
    price_id             BIGINT       NOT NULL,
    loading_date         DATE         NOT NULL,
    loading_city_gcid    INTEGER      NOT NULL,
    unloading_city_gcid  INTEGER      NOT NULL,
    body_group           text         NOT NULL,
    actual_price_rub     DOUBLE PRECISION,
    predicted_price_rub  DOUBLE PRECISION NOT NULL,
    abs_error_rub        DOUBLE PRECISION,
    ape_pct              DOUBLE PRECISION,
    model_name           text         NOT NULL,
    scored_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (price_id, body_group, model_name)
);

CREATE INDEX idx_ml_pred_date ON mart.ml_price_predictions (loading_date);
CREATE INDEX idx_ml_pred_route ON mart.ml_price_predictions (loading_city_gcid, unloading_city_gcid, loading_date);

