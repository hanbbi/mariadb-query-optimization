-- ============================================================
-- 03_index.sql
-- 복합·커버링 인덱스를 '무중단'으로 추가합니다.
--
-- 인덱스 구성: (reading_at, device_id, usage_value)
--   - reading_at 선두  : 월 범위 조건이 range scan을 타게 함(한 달치로 가지치기)
--   - device_id, usage_value 포함 : GROUP BY / SUM 에 필요한 값을 인덱스만으로 해결
--                                   => 원본 행 접근(테이블 룩업) 없이 커버링
--
-- ALGORITHM=INPLACE, LOCK=NONE
--   - 인덱스 생성 중에도 읽기/쓰기가 막히지 않습니다(운영 중 무중단 적용).
--   - 실패 시 MariaDB가 사유를 반환하므로, 그때는 점검 시간대에 재시도합니다.
-- ============================================================

ALTER TABLE meter_reading
    ADD INDEX idx_reading_at_device (reading_at, device_id, usage_value),
    ALGORITHM=INPLACE, LOCK=NONE;

-- 인덱스 확인
-- SHOW INDEX FROM meter_reading;

-- 참고: 왜 (device_id, reading_at) 가 아니라 (reading_at, ...) 인가?
--   이 쿼리는 '특정 월' 범위로 먼저 가지치기하는 것이 핵심이라 reading_at을 선두에 둡니다.
--   대신 GROUP BY device_id 는 범위 결과를 다시 그룹핑해야 해서 정렬 비용이 남습니다.
--   그 잔여 비용까지 없애는 것이 STAGE 3의 요약 테이블입니다. (트레이드오프는 README 참고)
