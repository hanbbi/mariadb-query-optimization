-- ============================================================
-- 01_schema.sql
-- 시계열 검침 데이터 원본 테이블
-- 처음에는 PK(id)만 둡니다. reading_at 인덱스를 일부러 두지 않아,
-- 개선 전 쿼리가 풀 스캔하는 상황을 재현하기 위함입니다.
-- ============================================================

DROP TABLE IF EXISTS meter_reading;

CREATE TABLE meter_reading (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    device_id   INT             NOT NULL,           -- 검침 단말기 ID
    reading_at  DATETIME        NOT NULL,           -- 검침 시각
    usage_value DECIMAL(12,3)   NOT NULL,           -- 구간 사용량
    created_at  TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4;

-- 적재 확인용
-- SELECT COUNT(*) FROM meter_reading;
-- SELECT MIN(reading_at), MAX(reading_at) FROM meter_reading;
