-- ============================================================
-- 04_summary_table.sql
-- 월별 요약 테이블 + 이중 유지 구조(실시간 트리거 + 일별 배치)
--
-- 문제: STAGE 2로 한 달치 range scan까지 줄였어도, 대시보드가 자주 호출되면
--       매번 수십~수백만 행을 다시 집계합니다.
-- 해결: (device_id, 월) 단위로 미리 집계해 두고, 대시보드는 이 작은 테이블만 읽습니다.
--
-- 유지 전략 두 가지를 '병행'합니다.
--   1) 실시간 트리거: INSERT 시 즉시 누적 -> 최신성 확보
--   2) 일별 배치 재계산: 하루 한 번 원본으로 재집계 -> 정합성 확보
--      (트리거는 지연/누락/수정/삭제에 취약하므로, 배치가 최종 정답을 맞춰줍니다)
-- ============================================================

DROP TABLE IF EXISTS monthly_meter_summary;

CREATE TABLE monthly_meter_summary (
    device_id     INT           NOT NULL,
    ym            CHAR(7)       NOT NULL,           -- 'YYYY-MM'
    total_usage   DECIMAL(18,3) NOT NULL DEFAULT 0,
    reading_count INT           NOT NULL DEFAULT 0,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                                         ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (device_id, ym)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4;


-- ---- (1) 최초 1회: 원본에서 요약 테이블을 채웁니다 --------------------
INSERT INTO monthly_meter_summary (device_id, ym, total_usage, reading_count)
SELECT device_id,
       DATE_FORMAT(reading_at, '%Y-%m') AS ym,
       SUM(usage_value),
       COUNT(*)
FROM   meter_reading
GROUP  BY device_id, DATE_FORMAT(reading_at, '%Y-%m');


-- ---- (2) 실시간 트리거: INSERT 시 요약 테이블 UPSERT ------------------
DELIMITER $$

CREATE TRIGGER trg_meter_reading_after_insert
AFTER INSERT ON meter_reading
FOR EACH ROW
BEGIN
    INSERT INTO monthly_meter_summary (device_id, ym, total_usage, reading_count)
    VALUES (NEW.device_id,
            DATE_FORMAT(NEW.reading_at, '%Y-%m'),
            NEW.usage_value,
            1)
    ON DUPLICATE KEY UPDATE
        total_usage   = total_usage   + NEW.usage_value,
        reading_count = reading_count + 1;
END$$

DELIMITER ;


-- ---- (3) 일별 배치 재계산(정합성 보정) --------------------------------
--   스케줄러(cron, 스프링 배치 등)가 하루 한 번, 전일/당월을 원본으로 재집계해
--   트리거 누적분과의 드리프트를 교정합니다. REPLACE 로 해당 (device_id, ym)만 덮어씁니다.
--   아래는 '당월 재계산' 예시입니다.
DELIMITER $$

CREATE PROCEDURE recalc_monthly_summary(IN p_ym CHAR(7))
BEGIN
    REPLACE INTO monthly_meter_summary (device_id, ym, total_usage, reading_count)
    SELECT device_id,
           DATE_FORMAT(reading_at, '%Y-%m'),
           SUM(usage_value),
           COUNT(*)
    FROM   meter_reading
    WHERE  reading_at >= STR_TO_DATE(CONCAT(p_ym, '-01'), '%Y-%m-%d')
      AND  reading_at <  STR_TO_DATE(CONCAT(p_ym, '-01'), '%Y-%m-%d') + INTERVAL 1 MONTH
    GROUP  BY device_id, DATE_FORMAT(reading_at, '%Y-%m');
END$$

DELIMITER ;

-- 배치 실행 예: CALL recalc_monthly_summary('2024-03');
