#!/usr/bin/env bash
# 각 단계의 쿼리를 ANALYZE FORMAT=JSON 으로 실측하고 결과를 results/ 에 저장합니다.
# 사용: bash scripts/run_benchmark.sh
set -euo pipefail

DB_CONTAINER="qopt-mariadb"
DB="qopt"
USER="root"
PW="rootpw"

run() {  # $1: 라벨, $2: SQL 파일 또는 인라인 SQL
  echo "==> $1"
  docker exec -i "$DB_CONTAINER" mariadb -u"$USER" -p"$PW" "$DB"
}

mkdir -p results

echo "각 쿼리는 2~3회 실행해 워밍업된 값을 기록하세요."
echo "sql/02_queries.sql 의 각 STAGE 블록을 순서대로 실행하면서"
echo "출력된 r_total_time_ms / r_rows 를 results/benchmark.md 표에 채우면 됩니다."
echo
echo "예시 실행:"
echo "  docker exec -i $DB_CONTAINER mariadb -u$USER -p$PW $DB < sql/02_queries.sql | tee results/analyze_raw.txt"
echo
echo "권장 순서:"
echo "  1) sql/01_schema.sql 적용"
echo "  2) 데이터 적재(README 참고)"
echo "  3) STAGE 0, STAGE 1 측정"
echo "  4) sql/03_index.sql 적용 후 STAGE 2 측정"
echo "  5) sql/04_summary_table.sql 적용 후 STAGE 3 측정"
