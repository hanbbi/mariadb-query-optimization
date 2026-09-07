-- ============================================================
-- 02_queries.sql
-- 개선 3단계를 순서대로 측정합니다.
-- 측정은 EXPLAIN(실행계획 예측)이 아니라 ANALYZE FORMAT=JSON(실제 실행 통계)으로 합니다.
--   - r_rows       : 실제로 읽은 행 수
--   - r_total_time_ms : 실제 소요 시간
-- 각 단계 전후로 아래 두 줄을 먼저 실행해 캐시 영향을 줄이세요.
--   SET GLOBAL innodb_flush_log_at_trx_commit = 1;
--   -- 그리고 각 쿼리는 2~3회 실행해 2회차 이후 값을 기록(워밍업된 안정값)
-- ============================================================


-- ------------------------------------------------------------
-- [STAGE 0] 개선 전: non-sargable 조건 (DATE_FORMAT)
--   WHERE 절에서 컬럼을 함수로 감싸면 인덱스를 못 탑니다(설령 있어도).
--   여기서는 인덱스도 없어 5천만 행을 전부 스캔합니다.
-- ------------------------------------------------------------
ANALYZE FORMAT=JSON
SELECT device_id, SUM(usage_value) AS total_usage
FROM   meter_reading
WHERE  DATE_FORMAT(reading_at, '%Y-%m') = '2024-03'
GROUP  BY device_id;


-- ------------------------------------------------------------
-- [STAGE 1] 조건을 sargable(범위 조건)로 교체
--   DATE_FORMAT(...) = '2024-03'  ->  reading_at >= '2024-03-01' AND < '2024-04-01'
--   아직 인덱스가 없어 풀 스캔이지만, 이제 인덱스를 '탈 수 있는' 형태가 됐습니다.
-- ------------------------------------------------------------
ANALYZE FORMAT=JSON
SELECT device_id, SUM(usage_value) AS total_usage
FROM   meter_reading
WHERE  reading_at >= '2024-03-01 00:00:00'
  AND  reading_at <  '2024-04-01 00:00:00'
GROUP  BY device_id;


-- ------------------------------------------------------------
-- [STAGE 2] 복합·커버링 인덱스를 무중단으로 추가한 뒤 같은 쿼리 재측정
--   인덱스는 sql/03_index.sql 에서 추가합니다(운영 무중단 옵션 포함).
--   추가 후 아래를 다시 실행하면 range scan + 커버링으로 바뀝니다.
-- ------------------------------------------------------------
ANALYZE FORMAT=JSON
SELECT device_id, SUM(usage_value) AS total_usage
FROM   meter_reading
WHERE  reading_at >= '2024-03-01 00:00:00'
  AND  reading_at <  '2024-04-01 00:00:00'
GROUP  BY device_id;


-- ------------------------------------------------------------
-- [STAGE 3] 요약 테이블 조회 (sql/04_summary_table.sql 적용 후)
--   대시보드는 매 조회마다 원본 한 달치를 훑는 대신,
--   미리 집계된 월별 요약 테이블(수천 행)만 읽습니다.
-- ------------------------------------------------------------
ANALYZE FORMAT=JSON
SELECT device_id, total_usage
FROM   monthly_meter_summary
WHERE  ym = '2024-03';
