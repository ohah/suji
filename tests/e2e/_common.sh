# Shared helpers for e2e runner scripts (run-window-*.sh).
# Each runner sources this and calls `e2e_run_test <test-file>` with optional
# SUJI_TRACE_IPC env. Sourced files don't need their own cleanup/wait/CEF-marker
# code — this file handles fresh `suji dev` lifecycle.
#
# Usage (in run-X.sh):
#   set -euo pipefail
#   ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
#   source "$ROOT/tests/e2e/_common.sh"
#   e2e_run_test tests/e2e/window-X.test.ts

# Caller MUST set: ROOT (project root).
# Caller MAY set: SUJI_LOG (log path), SUJI_TRACE_IPC (1 to enable trace).

: "${SUJI_LOG:=/tmp/suji-e2e.log}"
SUJI_BIN="$ROOT/zig-out/bin/suji"
EXAMPLE_DIR="$ROOT/examples/multi-backend"

e2e_cleanup() {
  pkill -TERM -f "zig-out/bin/suji" 2>/dev/null || true
  pkill -TERM -f "node.*vite" 2>/dev/null || true
  sleep 1
  pkill -9 -f "zig-out/bin/suji" 2>/dev/null || true
  pkill -9 -f "node.*vite" 2>/dev/null || true
}

e2e_wait_cef() {
  for _ in $(seq 1 60); do
    if grep -q "CEF running" "$SUJI_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: suji did not reach 'CEF running' within 120s"
  tail -30 "$SUJI_LOG" || true
  return 1
}

# e2e_run_test <test-file>
#   1. cleanup any prior suji/vite
#   2. launch fresh `suji dev` in examples/multi-backend (background, log → $SUJI_LOG)
#   3. wait for "CEF running" marker
#   4. `bun test <test-file>`
#   5. trap-driven cleanup on exit
e2e_run_test() {
  local test_file="$1"
  trap e2e_cleanup EXIT

  e2e_cleanup
  sleep 1
  rm -f "$SUJI_LOG"

  [ -x "$SUJI_BIN" ] || { echo "suji binary not found at $SUJI_BIN — run 'zig build' first"; exit 1; }

  cd "$EXAMPLE_DIR"
  if [ "${SUJI_TRACE_IPC:-}" = "1" ]; then
    SUJI_TRACE_IPC=1 "$SUJI_BIN" dev 2>&1 | tee "$SUJI_LOG" &
  else
    "$SUJI_BIN" dev 2>&1 | tee "$SUJI_LOG" &
  fi

  e2e_wait_cef || exit 1
  sleep 3 # vite/CEF 안정화

  cd "$ROOT"
  SUJI_LOG="$SUJI_LOG" bun test "$test_file"
}
