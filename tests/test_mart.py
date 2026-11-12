from etl.db import get_conn

def test_mart_route_card():
    """Проверка отсутствия дублей и корректности метрик."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            # 1. Нет дублей по ключу
            cur.execute("""
                select count(*) as cnt 
                  FROM (select month, 
                               loading_city_gcid, 
                               unloading_city_gcid, 
                               body_group, 
                               weight_category
                          from mart.mart_route_card
                         group by 1,2,3,4,5
                        having count(*) > 1
                       ) t
            """)
            assert cur.fetchone()['cnt'] == 0
            
            # 2. carriers_count не больше trips_count
            cur.execute("select count(*) as cnt from mart.mart_route_card where carriers_count > trips_count")
            assert cur.fetchone()['cnt'] == 0