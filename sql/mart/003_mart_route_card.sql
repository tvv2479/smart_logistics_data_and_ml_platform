
DROP MATERIALIZED VIEW IF EXISTS mart.mart_route_card CASCADE;

CREATE MATERIALIZED VIEW mart.mart_route_card AS
WITH params AS (
SELECT DATE '2026-10-26' AS as_of
       ),
       -- ----------------------------------------------------------------------------
       -- 1. Базовые факты: только завершённые/фактические прямые перевозки
       --    - is_fact = TRUE   (price_type IN 1,2,3,4,5,9)
       --    - complex = FALSE
       --    - outlier_mark = FALSE
       --    - price_rub > 0, distance > 0
       --    - price_date <= as_of (никакой будущей статистики)
       -- ----------------------------------------------------------------------------
       fact_base AS (
       SELECT p.price_id,
              p.organization_id,
              p.price_type,
              p.loading_city_gcid,
              p.unloading_city_gcid,
              p.distance,
              p.price_rub,
              p.weight_category,
              p.volume_category,
              p.body_type,
              DATE_TRUNC('month', pd.price_date)::date AS "month",
              p.price_rub / NULLIF(p.distance, 0) AS price_km
         FROM core.prices_clean p
         JOIN price_dates pd ON pd.price_id = p.price_id
        CROSS JOIN params
        WHERE p.is_fact = TRUE  
          AND p.complex      = FALSE
          AND p.outlier_mark = FALSE
          AND p.price_rub    > 0
          AND p.distance     > 0
          AND pd.price_date <= params.as_of
              ),
              -- ----------------------------------------------------------------------------
              -- 2. Унификация кузова: DISTINCT (price_id, body_group)
              --    Защита от fan-out: 207 сделок с {56,61} → 1 строка Тент
              --    LEFT JOIN + COALESCE: 1799 сделок без body_types → 'Не указан'
              -- ----------------------------------------------------------------------------
              body_grouped AS (
              SELECT DISTINCT
                     f.price_id,
                     COALESCE(
                          bg_pbt.body_group,   -- 1. основной: price_body_types → std_id → body_group
                          bg_bt.body_group,    -- 2. fallback: prices.body_type → std_id → body_group
                          'Не указан'          -- 3. финал
                     ) AS body_group
                FROM fact_base f
                -- 1. Основной путь: через M2M price_body_types
                LEFT JOIN price_body_types pbt
                  ON pbt.price_id = f.price_id
                LEFT JOIN mart.dim_body_group bg_pbt
                  ON bg_pbt.body_type_id = pbt.body_type_id
                -- 2. Fallback: prices.body_type → dim_body_group
                LEFT JOIN mart.dim_body_group bg_bt
                  ON bg_bt.body_type_id = f.body_type
                     ),
                     -- ----------------------------------------------------------------------------
                     -- 3. Обогащение: факты × группы кузова × dedup-города
                     -- ----------------------------------------------------------------------------
                     enriched AS (
                     SELECT f."month",
                            c_from.city AS loading_city,
                            c_to.city AS unloading_city,
                            f.loading_city_gcid,
                            f.unloading_city_gcid,
                            b.body_group,
                            f.weight_category,
                            f.volume_category,
                            f.price_id,
                            f.organization_id,
                            f.price_type,
                            f.price_rub,
                            f.price_km
                       FROM fact_base f
                       JOIN body_grouped b
                         ON b.price_id = f.price_id
                       JOIN mart.dim_cities_dedup c_from
                         ON c_from.gc_id = f.loading_city_gcid
                       JOIN mart.dim_cities_dedup c_to
                         ON c_to.gc_id   = f.unloading_city_gcid
                            ),
                            -- ----------------------------------------------------------------------------
                            -- 4. Агрегация в grain: month × from × to × body_group × weight_category
                            -- ----------------------------------------------------------------------------
                            agg AS (
                            SELECT e."month",
                                   e.loading_city_gcid,
                                   e.unloading_city_gcid,
                                   e.loading_city,
                                   e.unloading_city,
                                   e.body_group,
                                   e.weight_category,
                                   -- рыночный коридор за рейс (RUB)
                                   percentile_cont(0.25) WITHIN GROUP (ORDER BY e.price_rub) AS p25_trip,
                                   percentile_cont(0.50) WITHIN GROUP (ORDER BY e.price_rub) AS median_trip,
                                   percentile_cont(0.75) WITHIN GROUP (ORDER BY e.price_rub) AS p75_trip,
                                   avg(e.price_rub) AS avg_trip,
                                   -- рыночный коридор за км (RUB/км)
                                   percentile_cont(0.25) WITHIN GROUP (ORDER BY e.price_km) AS p25_km,
                                   percentile_cont(0.50) WITHIN GROUP (ORDER BY e.price_km) AS median_km,
                                   percentile_cont(0.75) WITHIN GROUP (ORDER BY e.price_km) AS p75_km,
                                   -- доказательная база
                                   COUNT(DISTINCT e.price_id) AS trips_count,
                                   COUNT(DISTINCT e.organization_id) FILTER (WHERE e.price_type IN (3, 9)) AS carriers_count,
                                   -- coefficient of variation
                                   STDDEV_SAMP(e.price_rub) / NULLIF(AVG(e.price_rub), 0) AS cv_rate,
                                   -- атрибут (не в grain): доминирующая volume_category в ячейке
                                   mode() WITHIN GROUP (ORDER BY e.volume_category) AS volume_category
                              FROM enriched e
                             GROUP BY e."month",
                                      e.loading_city_gcid, 
                                      e.unloading_city_gcid,
                                      e.loading_city,      
                                      e.unloading_city,
                                      e.body_group,
                                      e.weight_category
                                   ),
                                   -- ----------------------------------------------------------------------------
                                   -- 5. MoM / YoY через LAG с проверкой, что это именно соседний календарный
                                   --    месяц/год, а не «последний доступный»
                                   -- ----------------------------------------------------------------------------
                                   with_lag AS (
                                   SELECT a.*,
                                          LAG(a.median_trip) OVER w AS prev_median_1,
                                          LAG(a."month") OVER w AS prev_month_1,
                                          LAG(a.median_trip, 12) OVER w AS prev_median_12,
                                          LAG(a.month, 12)   OVER w AS prev_month_12
                                     FROM agg a
                                   WINDOW w AS (PARTITION BY a.loading_city_gcid, 
                                                             a.unloading_city_gcid,
                                                             a.body_group, 
                                                             a.weight_category
                                                    ORDER BY a."month")
                                          )
                                          SELECT w."month",
                                                 w.loading_city_gcid,
                                                 w.unloading_city_gcid,
                                                 w.loading_city,
                                                 w.unloading_city,
                                                 w.body_group,
                                                 w.weight_category,
                                                 w.volume_category,
                                                 w.p25_trip, w.median_trip, w.p75_trip, 
                                                 w.avg_trip,
                                                 w.p25_km, w.median_km, w.p75_km,
                                                 w.trips_count,
                                                 w.carriers_count,
                                                 w.cv_rate,
                                                 -- MoM: только если пред. месяц календарно соседний, иначе NULL
                                                 CASE
                                                 WHEN w.prev_month_1 = (w."month" - INTERVAL '1 month')::date
                                                  AND w.prev_median_1 > 0
                                                 THEN (w.median_trip - w.prev_median_1) / w.prev_median_1 * 100
                                                 ELSE NULL
                                                 END AS mom_pct,
                                                 -- YoY: только если ровно 12 месяцев назад
                                                 CASE
                                                 WHEN w.prev_month_12 = (w."month" - INTERVAL '12 months')::date
                                                  AND w.prev_median_12 > 0
                                                 THEN (w.median_trip - w.prev_median_12) / w.prev_median_12 * 100
                                                 ELSE NULL
                                                 END AS yoy_pct,
                                                 -- reliability_level
                                                 CASE
                                                 WHEN w.trips_count >= 30
                                                  AND w.carriers_count >= 5
                                                  AND (DATE '2026-10-26' - LEAST((w.month + INTERVAL '1 month' - INTERVAL '1 day')::date, DATE '2026-10-26')) <= 30
                                                 THEN 'HIGH'
                                                 WHEN w.trips_count >= 10 THEN 'MEDIUM'
                                                 ELSE 'LOW_DATA'
                                                 END AS reliability_level
                                            FROM with_lag w;


-- Unique index — нужен для одновременного обновления
CREATE UNIQUE INDEX IF NOT EXISTS uq_mart_route_card
    ON mart.mart_route_card ("month", loading_city_gcid, unloading_city_gcid, body_group, weight_category);

-- Дополнительные индексы под типовые запросы BI
CREATE INDEX IF NOT EXISTS idx_mart_route_card_route
    ON mart.mart_route_card (loading_city_gcid, unloading_city_gcid, month);
CREATE INDEX IF NOT EXISTS idx_mart_route_card_reliability
    ON mart.mart_route_card (reliability_level);









































