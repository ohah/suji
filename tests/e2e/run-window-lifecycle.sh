#!/usr/bin/env bash
# Phase 4-A — webContents 네비/JS + 창 생명주기 E2E 단독 실행 스크립트.
# (run-window-injection.sh와 동일 패턴 — 각 e2e 파일은 fresh suji dev에서
# 단독 실행해야 잔재 창 id 누적/target attach 충돌이 없음.)
#
# 수행:
#   1. 기존 suji dev / vite 프로세스 정리
#   2. examples/multi-backend에서 `suji dev`를 백그라운드로 띄우고 stderr를 $LOG로 tee
#   3. "CEF running" 마커가 로그에 찍힐 때까지 최대 120s 대기
#   4. `bun test tests/e2e/window-lifecycle.test.ts` 실행
#   5. 종료 시 suji + vite 정리

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="${SUJI_LOG:-/tmp/suji-e2e-lifecycle.log}"
SUJI_BIN="$ROOT/zig-out/bin/suji"
EXAMPLE_DIR="$ROOT/examples/multi-backend"

cleanup() {
  pkill -TERM -f "zig-out/bin/suji" 2>/dev/null || true
  pkill -TERM -f "node.*vite" 2>/dev/null || true
  sleep 1
  pkill -9 -f "zig-out/bin/suji" 2>/dev/null || true
  pkill -9 -f "node.*vite" 2>/dev/null || true
}
trap cleanup EXIT

cleanup
sleep 1
rm -f "$LOG"

[ -x "$SUJI_BIN" ] || { echo "suji binary not found at $SUJI_BIN — run 'zig build' first"; exit 1; }

cd "$EXAMPLE_DIR"
"$SUJI_BIN" dev 2>&1 | tee "$LOG" &

# CEF running 대기
for _ in $(seq 1 60); do
  if grep -q "CEF running" "$LOG" 2>/dev/null; then
    break
  fi
  sleep 2
done

if ! grep -q "CEF running" "$LOG" 2>/dev/null; then
  echo "ERROR: suji did not reach 'CEF running' within 120s"
  tail -30 "$LOG" || true
  exit 1
fi

sleep 3 # vite/CEF 안정화

cd "$ROOT"
SUJI_LOG="$LOG" bun test tests/e2e/window-lifecycle.test.ts
