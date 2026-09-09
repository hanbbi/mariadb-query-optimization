# 대용량 시계열 검침 데이터 쿼리 최적화

수천만 행짜리 검침 테이블에서 월별 사용량 집계가 점점 느려졌고, 그걸 잡은 과정을 로컬에서 재현할 수 있게 정리했습니다.
실무에선 회사 데이터로 했지만, 여기선 더미 데이터로 같은 흐름(진단 → 개선 → 측정)을 돌려볼 수 있습니다.

> 실무 운영 환경(약 5천만 행)에서 이 기법으로 핵심 집계 조회를 **약 10초 → 약 2초**로 단축했습니다.
> 이 저장소는 동일한 접근을 로컬 더미 데이터로 누구나 재현할 수 있게 코드로 정리한 것입니다.

---

## 문제

가스/검침 플랫폼의 대시보드는 "특정 월, 단말기별 사용량 합계"를 자주 조회합니다.
원본 테이블(`meter_reading`)이 수천만 행으로 커지자 이 집계 조회가 급격히 느려졌습니다.

처음 쿼리는 이런 형태였습니다.

```sql
SELECT device_id, SUM(usage_value)
FROM   meter_reading
WHERE  DATE_FORMAT(reading_at, '%Y-%m') = '2024-03'   -- 컬럼을 함수로 감쌈
GROUP  BY device_id;
```

`WHERE` 절에서 컬럼(`reading_at`)을 함수로 감싸면, 설령 인덱스가 있어도 인덱스를
탈 수 없습니다(non-sargable). 결과적으로 매 조회마다 전체 테이블을 스캔했습니다.

---

## 접근 — 3단계

측정은 실행계획 예측(`EXPLAIN`)이 아니라 **실제 실행 통계(`ANALYZE FORMAT=JSON`)**
로 했습니다. `r_rows`(실제 읽은 행)와 `r_total_time_ms`(실제 시간)를 근거로 삼습니다.

### STAGE 1 — 조건을 sargable(범위 조건)로 교체
```sql
WHERE reading_at >= '2024-03-01' AND reading_at < '2024-04-01'
```
함수 래핑을 걷어내 **인덱스를 탈 수 있는 형태**로 바꿉니다. (이 단계만으로는 인덱스가
없어 여전히 풀 스캔이지만, 다음 단계의 전제 조건입니다.)

### STAGE 2 — 복합·커버링 인덱스를 무중단으로 추가
```sql
ALTER TABLE meter_reading
  ADD INDEX idx_reading_at_device (reading_at, device_id, usage_value),
  ALGORITHM=INPLACE, LOCK=NONE;   -- 운영 중 읽기/쓰기 차단 없이 적용
```
- `reading_at` 선두: 월 범위로 **range scan** → 읽는 행이 급감
- `device_id, usage_value` 포함: 집계에 필요한 값을 인덱스만으로 해결 → **커버링**(테이블 룩업 없음)

### STAGE 3 — 트리거 + 배치 이중 구조의 월별 요약 테이블
STAGE 2로도 대시보드는 매 호출마다 한 달치를 다시 집계합니다. 자주 불리는 조회라면
미리 집계해 두는 편이 낫습니다.

```
INSERT into meter_reading ──(AFTER INSERT 트리거)──▶ monthly_meter_summary (실시간 누적)
                                                          ▲
                          일 1회 배치 재계산(원본 재집계) ─┘  (정합성 보정)
```
- **실시간 트리거**로 최신성을 확보하고,
- **일별 배치 재계산**으로 트리거가 놓칠 수 있는 지연/수정/삭제를 교정해 정합성을 맞춥니다.

대시보드는 이제 수천만 행이 아니라 요약 테이블의 수백 행만 읽습니다.

---

## 재현 방법

사전 요구: Docker, Python 3.

```bash
# 1) MariaDB 기동
docker compose up -d

# 2) 스키마 생성
docker exec -i qopt-mariadb mariadb -uroot -prootpw qopt < sql/01_schema.sql

# 3) 더미 데이터 생성(약 1,700만 행; 규모는 옵션으로 조절)
python scripts/generate_data.py --devices 500 \
  --start 2023-06-01 --end 2024-06-01 --interval-minutes 15 \
  --output data/meter_reading.csv

# 4) 데이터 적재 (LOAD DATA; INSERT보다 훨씬 빠름)
docker cp data/meter_reading.csv qopt-mariadb:/tmp/mr.csv
docker exec -i qopt-mariadb mariadb --local-infile=1 -uroot -prootpw qopt -e \
 "LOAD DATA LOCAL INFILE '/tmp/mr.csv' INTO TABLE meter_reading \
  FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' \
  (device_id, reading_at, usage_value);"

# 5) 단계별 측정
#   - STAGE 0/1 측정  (sql/02_queries.sql 의 해당 블록)
#   - sql/03_index.sql 적용 후 STAGE 2 측정
#   - sql/04_summary_table.sql 적용 후 STAGE 3 측정
docker exec -i qopt-mariadb mariadb -uroot -prootpw qopt < sql/02_queries.sql
```

측정값은 [results/benchmark.md](results/benchmark.md)의 표에 채웁니다.

---

## 트레이드오프 / 배운 점

- **non-sargable의 본질은 "함수라서 느린 것"이 아니라 "인덱스를 못 타는 것"입니다.**
  STAGE 0 → 1에서 시간이 거의 안 줄어드는 것으로 이 점을 확인할 수 있습니다.
- 인덱스 컬럼 순서는 공짜가 아닙니다. `(reading_at, ...)`는 월 범위 가지치기에 최적이지만,
  `GROUP BY device_id`는 범위 결과를 다시 그룹핑해야 해 정렬 비용이 남습니다.
  그 잔여 비용까지 없애려는 것이 요약 테이블입니다.
- 요약 테이블은 **실시간성과 정합성이 상충**합니다. 트리거만 쓰면 빠르지만 드리프트가
  생기고, 배치만 쓰면 정확하지만 최신이 아닙니다. 그래서 **둘을 병행**했습니다.
- 운영 테이블 인덱스 추가는 잠금을 유발할 수 있어 `ALGORITHM=INPLACE, LOCK=NONE`으로
  무중단 적용했습니다.

---

## 저장소 구조

```
.
├── docker-compose.yml         # 원커맨드 MariaDB
├── sql/
│   ├── 01_schema.sql          # 원본 테이블(초기엔 PK만)
│   ├── 02_queries.sql         # STAGE 0~3 측정 쿼리(ANALYZE FORMAT=JSON)
│   ├── 03_index.sql           # 복합·커버링 인덱스 무중단 추가
│   └── 04_summary_table.sql   # 요약 테이블 + 트리거 + 배치 프로시저
├── scripts/
│   ├── generate_data.py       # 더미 데이터 CSV 생성
│   └── run_benchmark.sh       # 측정 절차 안내
└── results/
    └── benchmark.md           # 측정 결과 표(직접 기록)
```
