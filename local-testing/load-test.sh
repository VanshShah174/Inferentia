#!/usr/bin/env bash
# =============================================================================
# vLLM load test — fire N requests with bounded concurrency, then summarize.
# =============================================================================
# Usage: ./load-test.sh [TOTAL] [CONCURRENCY] [URL]
#   TOTAL        number of requests            (default 100)
#   CONCURRENCY  max in-flight at once         (default 8)
#   URL          endpoint                      (default http://localhost:8000/v1/chat/completions)
#
# Alternates traffic-a / traffic-b (shared system prompt -> prefix-cache).
# Writes per-request "http_code time_total" lines to a temp file, then prints
# a summary: success count, wall-clock, throughput, and latency percentiles.
# =============================================================================
set -u

TOTAL="${1:-100}"
CONCURRENCY="${2:-8}"
PORT="${4:-8000}"
URL="${3:-}"

# If no URL given, figure out a reachable host. Under WSL, localhost does NOT
# reach a Windows-side kubectl port-forward, so fall back to the Windows host
# IP (the default gateway inside WSL2).
if [ -z "$URL" ]; then
  HOST="localhost"
  if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
    if ! curl -s -o /dev/null --max-time 3 "http://localhost:${PORT}/v1/models"; then
      WINIP="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
      [ -n "$WINIP" ] && HOST="$WINIP"
    fi
  fi
  URL="http://${HOST}:${PORT}/v1/chat/completions"
fi
echo ">> target: ${URL}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TA="${SCRIPT_DIR}/kind/traffic-a.json"
TB="${SCRIPT_DIR}/kind/traffic-b.json"
OUT="$(mktemp)"

echo ">> firing ${TOTAL} requests at ${URL} (concurrency=${CONCURRENCY})"
start=$(date +%s)

for i in $(seq 1 "$TOTAL"); do
  if (( i % 2 == 0 )); then f="$TB"; else f="$TA"; fi
  # -o /dev/null: discard body; -w: record "code total_seconds"
  curl -s -o /dev/null -w "%{http_code} %{time_total}\n" \
    -X POST "$URL" \
    -H "Content-Type: application/json" \
    --data "@${f}" --max-time 180 >> "$OUT" &

  # throttle: when we hit CONCURRENCY in-flight, wait for one to finish
  while (( $(jobs -r -p | wc -l) >= CONCURRENCY )); do
    wait -n 2>/dev/null || true
  done
done
wait
end=$(date +%s)

wall=$(( end - start ))
[ "$wall" -eq 0 ] && wall=1

total_lines=$(wc -l < "$OUT")
ok=$(awk '$1==200' "$OUT" | wc -l)
fail=$(( total_lines - ok ))

echo ""
echo "=== RESULTS ==="
echo "total=${total_lines}  ok=${ok}  failed=${fail}"
echo "wall_clock=${wall}s  throughput=$(awk "BEGIN{printf \"%.2f\", ${total_lines}/${wall}}") req/s"

# latency percentiles over successful requests (seconds -> ms), sorted
awk '$1==200 {printf "%d\n", $2*1000}' "$OUT" | sort -n > "${OUT}.lat"
n=$(wc -l < "${OUT}.lat")
if [ "$n" -gt 0 ]; then
  p() { sed -n "$(( ($1*n/100) < 1 ? 1 : $1*n/100 ))p" "${OUT}.lat"; }
  echo "latency ms: min=$(sed -n '1p' "${OUT}.lat")  p50=$(p 50)  p90=$(p 90)  p99=$(p 99)  max=$(tail -1 "${OUT}.lat")"
fi

if [ "$fail" -gt 0 ]; then
  echo "failed codes: $(awk '$1!=200 {print $1}' "$OUT" | sort | uniq -c | awk '{printf "%sx%s ", $2, $1}')"
fi

rm -f "$OUT" "${OUT}.lat"
