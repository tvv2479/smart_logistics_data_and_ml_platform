
-- Унификация кузова по std_id из body_types → бизнес-группа.

DROP TABLE IF EXISTS mart.dim_body_group;

CREATE TABLE mart.dim_body_group AS
SELECT id AS body_type_id,
       std_id,
       name,
       CASE
       WHEN std_id = 56  THEN 'Тент'
       WHEN std_id = 4   THEN 'Рефрижератор'
       WHEN std_id = 2   THEN 'Изотерм'
       WHEN std_id = 15  THEN 'Борт'
       WHEN std_id IS NULL THEN 'Не указан'
       ELSE 'Прочие'
       END  AS body_group
  FROM body_types;

ALTER TABLE mart.dim_body_group ADD PRIMARY KEY (body_type_id);

CREATE INDEX IF NOT EXISTS idx_dim_body_group_std ON mart.dim_body_group (std_id);



