
-- Дедуплицированный справочник городов: gc_id → MIN(id).
-- Защита от размножения сделок при JOIN по gc_id (Москва 1001 × 2, Казань 1003 × 2).

CREATE SCHEMA IF NOT EXISTS mart;

DROP TABLE IF EXISTS mart.dim_cities_dedup;

CREATE TABLE mart.dim_cities_dedup AS
WITH dedup AS (
SELECT gc_id, MIN(id) AS city_id
  FROM cities
 GROUP BY gc_id
       )
       SELECT c.gc_id,
              c.id AS city_id,
              TRIM(split_part(c.full_name_local, ',', 1)) AS city,
              CASE
              WHEN c.full_name_local LIKE '%,%' THEN TRIM(regexp_replace(c.full_name_local, '^[^,]+,', ''))
              ELSE NULL
              END AS region,
              c.latitude,
              c.longitude,
              c.full_name_local
         FROM cities c
         JOIN dedup d ON d.city_id = c.id;

ALTER TABLE mart.dim_cities_dedup ADD PRIMARY KEY (gc_id);

CREATE INDEX IF NOT EXISTS idx_dim_cities_dedup_city ON mart.dim_cities_dedup (city);












