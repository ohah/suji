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

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) SUJI_E2E_WINDOWS=1 ;;
  *) SUJI_E2E_WINDOWS=0 ;;
esac

if [ "$SUJI_E2E_WINDOWS" = "1" ] && [ -n "${SUJI_LOG:-}" ] && command -v cygpath >/dev/null 2>&1; then
  SUJI_LOG="$(cygpath -u "$SUJI_LOG")"
fi
: "${SUJI_LOG:=/tmp/suji-e2e.log}"

if [ "$SUJI_E2E_WINDOWS" = "1" ]; then
  SUJI_BIN="$ROOT/zig-out/bin/suji.exe"
else
  SUJI_BIN="$ROOT/zig-out/bin/suji"
fi
EXAMPLE_DIR="$ROOT/examples/multi-backend"

e2e_cleanup() {
  if [ "$SUJI_E2E_WINDOWS" = "1" ]; then
    powershell -NoProfile -ExecutionPolicy Bypass -Command \
      'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*zig-out*suji.exe*" -or $_.CommandLine -like "*node* vite*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' \
      >/dev/null 2>&1 || true
  else
    pkill -TERM -f "zig-out/bin/suji" 2>/dev/null || true
    pkill -TERM -f "node.*vite" 2>/dev/null || true
    sleep 1
    pkill -9 -f "zig-out/bin/suji" 2>/dev/null || true
    pkill -9 -f "node.*vite" 2>/dev/null || true
  fi
}

e2e_wait_cef() {
  for _ in $(seq 1 60); do
    if grep -q "CEF running" "$SUJI_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: suji did not reach 'CEF running' within 120s"
  echo "SUJI_LOG=$SUJI_LOG"
  tail -30 "$SUJI_LOG" || true
  if command -v ps >/dev/null 2>&1; then
    echo "---- suji/vite process snapshot ----"
    ps -ef | grep -E '([s]uji|[v]ite|--type=|zygote|gpu-process|renderer)' || true
  fi
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
  echo "Launching $SUJI_BIN dev in $EXAMPLE_DIR"
  echo "Writing suji log to $SUJI_LOG"
  if [ "${SUJI_TRACE_IPC:-}" = "1" ]; then
    SUJI_TRACE_IPC=1 "$SUJI_BIN" dev 2>&1 | tee "$SUJI_LOG" &
  else
    "$SUJI_BIN" dev 2>&1 | tee "$SUJI_LOG" &
  fi

  e2e_wait_cef || exit 1
  sleep 3 # vite/CEF 안정화

  cd "$ROOT"
  SUJI_LOG="$SUJI_LOG" bun test "$test_file" --timeout 30000 2>&1 | tee -a "$SUJI_LOG"
}
