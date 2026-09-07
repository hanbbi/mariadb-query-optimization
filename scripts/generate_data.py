#!/usr/bin/env python3
"""
시계열 검침 더미 데이터 생성기.

수천만 행을 INSERT 문으로 넣으면 매우 느리므로, CSV로 뽑은 뒤
LOAD DATA LOCAL INFILE 로 한 번에 적재합니다(권장).

예)
    # 약 1,700만 행 (500대 x 15분 간격 x 약 1년)
    python scripts/generate_data.py \
        --devices 500 \
        --start 2023-06-01 \
        --end   2024-06-01 \
        --interval-minutes 15 \
        --output data/meter_reading.csv

    # 실무 규모(약 5천만 행)에 맞추려면 devices 를 늘리거나 기간을 넓히세요.
    #   1500대 x 15분 x 약 1년 ≈ 5,200만 행

적재:
    docker exec -i qopt-mariadb mariadb --local-infile=1 -uroot -prootpw qopt \
      -e "LOAD DATA LOCAL INFILE 'data/meter_reading.csv' \
          INTO TABLE meter_reading \
          FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' \
          (device_id, reading_at, usage_value);"
    # (컨테이너 안에서 파일 경로를 못 찾으면, CSV를 컨테이너로 복사하거나
    #  호스트 클라이언트에서 실행하세요. README의 '데이터 적재' 참고)
"""
import argparse
import csv
import random
from datetime import datetime, timedelta


def parse_args():
    p = argparse.ArgumentParser(description="검침 더미 데이터 CSV 생성")
    p.add_argument("--devices", type=int, default=500, help="단말기 수")
    p.add_argument("--start", default="2023-06-01", help="시작일 YYYY-MM-DD")
    p.add_argument("--end", default="2024-06-01", help="종료일(미포함) YYYY-MM-DD")
    p.add_argument("--interval-minutes", type=int, default=15, help="검침 간격(분)")
    p.add_argument("--output", default="data/meter_reading.csv", help="출력 CSV 경로")
    p.add_argument("--seed", type=int, default=42, help="난수 시드(재현성)")
    return p.parse_args()


def main():
    args = parse_args()
    random.seed(args.seed)

    start = datetime.strptime(args.start, "%Y-%m-%d")
    end = datetime.strptime(args.end, "%Y-%m-%d")
    step = timedelta(minutes=args.interval_minutes)

    # 단말기별 기본 소비 성향(대략적인 현실감 부여)
    base = {d: random.uniform(0.2, 3.0) for d in range(1, args.devices + 1)}

    slots = int((end - start) / step)
    total = slots * args.devices
    print(f"생성 예정 행 수: 약 {total:,} (slots={slots:,} x devices={args.devices})")

    written = 0
    with open(args.output, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")   # LOAD DATA 의 '\n' 종결과 일치
        t = start
        while t < end:
            ts = t.strftime("%Y-%m-%d %H:%M:%S")
            # 시간대별 사용량 가중치(낮에 조금 더 씀)
            hour_factor = 1.0 + 0.5 * (6 <= t.hour <= 22)
            for d in range(1, args.devices + 1):
                usage = round(base[d] * hour_factor * random.uniform(0.5, 1.5), 3)
                w.writerow([d, ts, usage])
                written += 1
            t += step
            if written and written % 2_000_000 == 0:
                print(f"  ... {written:,} 행 작성")

    print(f"완료: {written:,} 행 -> {args.output}")


if __name__ == "__main__":
    main()
