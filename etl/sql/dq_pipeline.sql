

-- =============================================================================
-- ETL: raw.prices -> core.prices_clean + core.dq_quarantine_prices
-- Окно: loading_date in [%(start)s, %(end_plus_1)s)
-- Идемпотентность: DELETE партиции + INSERT в одной транзакции
-- Валюты: точный курс по nearest_rate_date, без fallback
-- Выбросы: outlier_mark сохраняется как есть, пересчёт НЕ делается
-- =============================================================================

-- begin;

-- -----------------------------------------------------------------------------
-- 1. Перезапись партиции (гарантия идемпотентности при backfill)
-- -----------------------------------------------------------------------------
delete from core.prices_clean
 where loading_date >= %(start)s
   and loading_date <  %(end_plus_1)s;

delete from core.dq_quarantine_prices
 where loading_date >= %(start)s
   and loading_date <  %(end_plus_1)s;

-- -----------------------------------------------------------------------------
-- 2. Классификация: для каждой строки окна вычисляем причину отбраковки (NULL = валидная)
-- -----------------------------------------------------------------------------
create temp table tmp_classified on commit drop as
with base as (
select p.id AS price_id,
       p.loading_date,
       p.loading_city_gcid,
       p.unloading_city_gcid,
       p.organization_id,
       p.distance,
       p.total_weight,
       p.total_volume,
       p.body_type,
       p.price as price_src,
       p.currency_code, -- varchar(3): '643' / '840' / '978'
       p.price_type,
       p.is_fact,
       p.complex,
       p.nearest_rate_date,
       p.outlier_mark,
       -- «город существует в справочнике»
       (c_load.gc_id  is not null) as load_city_ok,
       (c_unload.gc_id is not null) as unload_city_ok,
        -- курс: RUB = 1.0, иначе ищем точный по (num_code, setting_date = nearest_rate_date)
        case
        when p.currency_code = '643' then 1.0
        else er.value
        end as exchange_rate
   from prices p
   left join (select distinct gc_id from cities) c_load
     on c_load.gc_id = p.loading_city_gcid
   left join (select distinct gc_id from cities) c_unload
     on c_unload.gc_id = p.unloading_city_gcid
   left join exchange_rates er
     on er.num_code     = p.currency_code
    and er.setting_date = p.nearest_rate_date
  where p.loading_date >= %(start)s
    and p.loading_date <  %(end_plus_1)s
        ),
        classified as (
        select b.*,
               -- Порядок CASE задаёт «первую» причину для оперативных отчётов.
               -- В карантин попадёт именно эта причина (одна запись на строку).
               case
               when b.price_src is null or b.price_src <= 0
               then 'invalid_price_nonpositive'
               when b.currency_code = '643' and b.price_src <= 1000 
               then 'invalid_price_rub_below_floor'
               when b.distance is null or b.distance <= 0 
               then 'invalid_distance'
               when b.total_weight is null or b.total_weight < 0 
               then 'invalid_weight'
               when b.total_volume is null or b.total_volume < 0 
               then 'invalid_volume'
               when not b.load_city_ok 
               then 'unknown_loading_city'
               when not b.unload_city_ok 
               then 'unknown_unloading_city'
               -- валютная строка без точного курса на nearest_rate_date
               -- (fallback на loading_date НЕ делаем)
               when b.currency_code <> '643' and (b.nearest_rate_date is null or b.exchange_rate is null) 
                then 'missing_exchange_rate'
               else null
               end as dq_reason
          from base b
               )
               select * from classified;

-- -----------------------------------------------------------------------------
-- 3. Карантин: все строки с причиной payload — снимок полей, чтобы потом восстановить контекст
-- -----------------------------------------------------------------------------
insert into core.dq_quarantine_prices (
       price_id, loading_date, loading_city_gcid, unloading_city_gcid,
       price_src, currency_code, reason_code, payload
       )
       select price_id, 
              loading_date, 
              loading_city_gcid, 
              unloading_city_gcid,
              price_src, currency_code, dq_reason,
              jsonb_build_object(
              'distance',          distance,
              'total_weight',      total_weight,
              'total_volume',      total_volume,
              'body_type',         body_type,
              'price_type',        price_type,
              'is_fact',           is_fact,
              'complex',           complex,
              'nearest_rate_date', nearest_rate_date,
              'exchange_rate',     exchange_rate
              )
         from tmp_classified
        where dq_reason is not null
           on conflict (price_id, reason_code) do nothing;

-- -----------------------------------------------------------------------------
-- 4. Чистые данные: валидные строки, уже в RUB, с категориями
--    weight_category / volume_category ПЕРЕСЧИТЫВАЕМ всегда
--    (в источнике nullable и может содержать грязь)
-- -----------------------------------------------------------------------------
INSERT INTO core.prices_clean (
       price_id, loading_date, loading_city_gcid, unloading_city_gcid,
       organization_id, distance, total_weight, total_volume, body_type,
       price_src, currency_code, exchange_rate, price_rub,
       weight_category, volume_category,
       price_type, is_fact, complex, outlier_mark
       )
       select price_id, 
              loading_date, 
              loading_city_gcid, 
              unloading_city_gcid,
              organization_id, 
              distance, 
              total_weight, 
              total_volume, 
              body_type,
              price_src, 
              currency_code, 
              exchange_rate,
              -- конвертация в RUB без НДС
              round((price_src * exchange_rate)::numeric, 2)::float8 as price_rub,
              -- весовая категория: границы по округлённому до 0.1 т весу
              case
              when total_weight is null then 'OTH'
              when round(total_weight::numeric, 1) >= 30 then 'G20T'
              when round(total_weight::numeric, 1) >= 10 then 'FTL'
              when round(total_weight::numeric, 1) >= 5 then '10T'
              when round(total_weight::numeric, 1) >= 2.5 then '5T'
              when round(total_weight::numeric, 1) >= 0.5 then 'L5T'
              else 'OTH'
              end as weight_category,
              -- объёмная категория
              case
              when total_volume > 0 and total_volume <= 120 then 'FTL'
              else 'OTH'
              end as volume_category,
              price_type, is_fact, complex, outlier_mark
         from tmp_classified
        where dq_reason is null
           on conflict (price_id) do update set 
              loading_date = EXCLUDED.loading_date,
              loading_city_gcid = EXCLUDED.loading_city_gcid,
              unloading_city_gcid = EXCLUDED.unloading_city_gcid,
              organization_id = EXCLUDED.organization_id,
              distance = EXCLUDED.distance,
              total_weight = EXCLUDED.total_weight,
              total_volume = EXCLUDED.total_volume,
              body_type = EXCLUDED.body_type,
              price_src = EXCLUDED.price_src,
              currency_code = EXCLUDED.currency_code,
              exchange_rate = EXCLUDED.exchange_rate,
              price_rub = EXCLUDED.price_rub,
              weight_category = EXCLUDED.weight_category,
              volume_category = EXCLUDED.volume_category,
              price_type = EXCLUDED.price_type,
              is_fact = EXCLUDED.is_fact,
              complex = EXCLUDED.complex,
              outlier_mark = EXCLUDED.outlier_mark,
              loaded_at = now();

-- -----------------------------------------------------------------------------
-- 5. Возврат статистики для Python-обёртки (одна строка)
-- -----------------------------------------------------------------------------
select (select count(*) from tmp_classified) AS rows_read,
       (select count(*) from tmp_classified where dq_reason is null) as rows_loaded,
       (select count(*) from tmp_classified where dq_reason is not null) as rows_quarantined;

-- commit;