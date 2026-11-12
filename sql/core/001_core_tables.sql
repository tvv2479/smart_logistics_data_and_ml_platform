
CREATE SCHEMA IF NOT EXISTS core;

-- Очищенные и обогащённые факты
CREATE TABLE IF NOT EXISTS core.prices_clean (
    price_id            BIGINT PRIMARY KEY,
    loading_date        DATE             NOT NULL,
    loading_city_gcid   INTEGER          NOT NULL,
    unloading_city_gcid INTEGER          NOT NULL,
    organization_id     INTEGER,
    distance            DOUBLE PRECISION,
    total_weight        DOUBLE PRECISION,
    total_volume        DOUBLE PRECISION,
    body_type           INTEGER,
    price_src           DOUBLE PRECISION,
    currency_code       VARCHAR(3)       NOT NULL,
    exchange_rate       DOUBLE PRECISION,
    price_rub           DOUBLE PRECISION,
    weight_category     VARCHAR(4),
    volume_category     VARCHAR(4),
    price_type          SMALLINT,
    is_fact             BOOLEAN,
    complex             BOOLEAN,
    outlier_mark        BOOLEAN,
    loaded_at           timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_prices_clean_loading_date ON core.prices_clean (loading_date);
CREATE INDEX IF NOT EXISTS idx_prices_clean_route ON core.prices_clean (loading_city_gcid, unloading_city_gcid, loading_date);

-- Карантин DQ
CREATE TABLE IF NOT EXISTS core.dq_quarantine_prices (
    price_id            BIGINT,
    loading_date        DATE,
    loading_city_gcid   INTEGER,
    unloading_city_gcid INTEGER,
    price_src           DOUBLE PRECISION,
    currency_code       VARCHAR(3),
    reason_code         text NOT NULL,
    payload             jsonb,
    run_id              BIGINT,
    quarantined_at      timestamptz DEFAULT now(),
    PRIMARY KEY (price_id, reason_code)
);
CREATE INDEX IF NOT EXISTS idx_dq_quarantine_loading_date ON core.dq_quarantine_prices (loading_date);
CREATE INDEX IF NOT EXISTS idx_dq_quarantine_reason ON core.dq_quarantine_prices (reason_code);

-- Журнал прогонов ETL
CREATE TABLE IF NOT EXISTS core.etl_run_log (
    run_id           bigserial PRIMARY KEY,
    start_date       DATE NOT NULL,
    end_date         DATE NOT NULL,
    stage            text NOT NULL,
    status           text NOT NULL,
    rows_read        BIGINT,
    rows_loaded      BIGINT,
    rows_quarantined BIGINT,
    started_at       timestamptz DEFAULT now(),
    finished_at      timestamptz,
    error            text
);