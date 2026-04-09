#!/usr/bin/env bash
set -euo pipefail

# CrystalDiskMark-like benchmark using fio (Linux)
# Usage: ./cdm_like_bench.sh [path] [size]
# Example: ./cdm_like_bench.sh /tmp/fio-testfile 1G

TESTFILE="${1:-/tmp/fio-testfile}"
SIZE="${2:-1G}"
RUNTIME="${RUNTIME:-30}"
JOBS="${JOBS:-1}"
ROUNDS="${ROUNDS:-5}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Thiếu '$1'. Cài bằng: sudo apt install -y $1" >&2
    exit 1
  }
}

require fio
require python3

run_fio() {
  local name="$1" rw="$2" bs="$3" iodepth="$4";
  local tmp log
  tmp=$(mktemp)
  log=$(mktemp)
  if ! fio --name="$name" --rw="$rw" --bs="$bs" --size="$SIZE" \
      --numjobs="$JOBS" --iodepth="$iodepth" --direct=1 --ioengine=libaio \
      --runtime="$RUNTIME" --time_based --group_reporting \
      --filename="$TESTFILE" --output-format=json --output="$tmp" \
      >/dev/null 2>"$log"; then
    echo "Lỗi: fio chạy không thành công." >&2
    cat "$log" >&2
    rm -f "$tmp" "$log"
    exit 1
  fi
  if [ ! -s "$tmp" ]; then
    echo "Lỗi: fio không xuất JSON (file rỗng)." >&2
    cat "$log" >&2
    rm -f "$tmp" "$log"
    exit 1
  fi
  echo "$tmp"
  rm -f "$log"
}

parse_bw_mibs() {
  local rw="$1" file="$2"
  python3 - "$rw" "$file" <<'PY'
import json,sys
rw = sys.argv[1]
path = sys.argv[2]
with open(path, 'r') as f:
    j=json.load(f)
# fio json: read/write bw is in KiB/s
bw = j['jobs'][0][rw]['bw']
# Convert KiB/s -> MiB/s
print(f"{bw/1024:.1f}")
PY
}

bench_row() {
  local label="$1" rw="$2" bs="$3" iodepth="$4";
  local jsonkey="$rw"
  if [ "$rw" = "randread" ]; then jsonkey="read"; fi
  if [ "$rw" = "randwrite" ]; then jsonkey="write"; fi
  local sum=0
  local i out bw
  for i in $(seq 1 "$ROUNDS"); do
    out=$(run_fio "$label" "$rw" "$bs" "$iodepth")
    if [ -z "$out" ]; then
      echo "Lỗi: fio không trả JSON (output rỗng)." >&2
      exit 1
    fi
    if [ "${DEBUG:-0}" = "1" ]; then
      echo "[DEBUG] $label json head:" >&2
      head -c 200 "$out" >&2
      echo >&2
    fi
    bw=$(parse_bw_mibs "$jsonkey" "$out")
    if [ "${DEBUG:-0}" = "1" ]; then
      echo "[DEBUG] $label bw=${bw} MiB/s" >&2
    fi
    sum=$(awk -v a="$sum" -v b="$bw" 'BEGIN{printf "%.6f", a+b}')
    rm -f "$out"
  done
  awk -v s="$sum" -v r="$ROUNDS" 'BEGIN{printf "%.1f", s/r}'
}

# Pre-create file (fio will create if missing)

# SEQ1M Q8T1
SEQ_Q8T1_R=$(bench_row "seq1m_q8t1_r" read 1m 8)
SEQ_Q8T1_W=$(bench_row "seq1m_q8t1_w" write 1m 8)

# SEQ1M Q1T1
SEQ_Q1T1_R=$(bench_row "seq1m_q1t1_r" read 1m 1)
SEQ_Q1T1_W=$(bench_row "seq1m_q1t1_w" write 1m 1)

# RND4K Q32T1
RND4K_Q32T1_R=$(bench_row "rnd4k_q32t1_r" randread 4k 32)
RND4K_Q32T1_W=$(bench_row "rnd4k_q32t1_w" randwrite 4k 32)

# RND4K Q1T1
RND4K_Q1T1_R=$(bench_row "rnd4k_q1t1_r" randread 4k 1)
RND4K_Q1T1_W=$(bench_row "rnd4k_q1t1_w" randwrite 4k 1)

printf "\nDisk Benchmark Results (MiB/s) — avg of %s runs\n" "$ROUNDS"
printf "%s\n" "-----------------------------------------------------------"
printf "%-15s %12s %14s\n" "Test" "Read" "Write"
printf "%-15s %12s %14s\n" "SEQ1M Q8T1" "$SEQ_Q8T1_R" "$SEQ_Q8T1_W"
printf "%-15s %12s %14s\n" "SEQ1M Q1T1" "$SEQ_Q1T1_R" "$SEQ_Q1T1_W"
printf "%-15s %12s %14s\n" "RND4K Q32T1" "$RND4K_Q32T1_R" "$RND4K_Q32T1_W"
printf "%-15s %12s %14s\n" "RND4K Q1T1" "$RND4K_Q1T1_R" "$RND4K_Q1T1_W"
printf "%s\n" "-----------------------------------------------------------"
printf "Test file: %s (size=%s, runtime=%ss)\n" "$TESTFILE" "$SIZE" "$RUNTIME"

rm -f "$TESTFILE"
