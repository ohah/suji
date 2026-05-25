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
SUJI_PID=""

e2e_cleanup() {
  if [ -n "${SUJI_PID:-}" ]; then
    kill "$SUJI_PID" >/dev/null 2>&1 || true
  fi
  if [ "$SUJI_E2E_WINDOWS" = "1" ]; then
    # 패턴: zig-out\suji.exe (메인 + CEF subprocess), bun frontend dev wrap,
    # vite.cmd/.exe stub, node vite.js (실제 dev server). 기존엔 `*node* vite*`
    # 만 봤는데 `node "..\vite.js"` 의 따옴표 때문에 매칭 실패 → tee 가 stdout
    # pipe 를 잡고 있어 호출자 substitution 이 EOF 대기로 행. 모든 frontend
    # 도구를 명시적으로 잡는다.
    #
    # scope 주의: vite.exe / bun.exe 는 시스템 어디서나 실행될 수 있어 process
    # name 만으로 잡지 않는다. CommandLine 에 `--cwd frontend` (bun spawn 패턴)
    # 또는 `node_modules*vite` (vite dev server) 또는 `zig-out*suji.exe` (백엔드)
    # 가 들어가야 매칭 — 개발자가 별개 vite/bun 프로젝트를 동시에 띄워도 영향 X.
    powershell -NoProfile -ExecutionPolicy Bypass -Command \
      'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*zig-out*suji.exe*" -or $_.CommandLine -like "*bun*--cwd*frontend*" -or $_.CommandLine -like "*node_modules*vite*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' \
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
  local timeout_seconds="${SUJI_E2E_STARTUP_TIMEOUT_SECONDS:-240}"
  local attempts=$(( (timeout_seconds + 1) / 2 ))
  for _ in $(seq 1 "$attempts"); do
    if grep -q "CEF running" "$SUJI_LOG" 2>/dev/null; then
      return 0
    fi
    if [ -n "${SUJI_PID:-}" ] && ! kill -0 "$SUJI_PID" >/dev/null 2>&1; then
      echo "ERROR: suji exited before 'CEF running'"
      wait "$SUJI_PID" || true
      tail -60 "$SUJI_LOG" || true
      return 1
    fi
    sleep 2
  done
  echo "ERROR: suji did not reach 'CEF running' within ${timeout_seconds}s"
  echo "SUJI_LOG=$SUJI_LOG"
  tail -30 "$SUJI_LOG" || true
  if [ -n "${SUJI_PID:-}" ]; then
    echo "---- suji pid diagnostics: $SUJI_PID ----"
    ps -p "$SUJI_PID" -o pid,ppid,stat,etime,command || true
    if [ -r "/proc/$SUJI_PID/wchan" ]; then
      echo "wchan: $(cat "/proc/$SUJI_PID/wchan" 2>/dev/null || true)"
    fi
    if [ -r "/proc/$SUJI_PID/status" ]; then
      sed -n '1,80p' "/proc/$SUJI_PID/status" || true
    fi
  fi
  if command -v ps >/dev/null 2>&1; then
    echo "---- suji/vite process snapshot ----"
    ps -ef | grep -E '([s]uji|[v]ite|--type=|zygote|gpu-process|renderer)' || true
  fi
  if [ -n "${SUJI_E2E_STRACE_DIR:-}" ]; then
    echo "---- strace tail ----"
    find "$SUJI_E2E_STRACE_DIR" -maxdepth 1 -type f -print -exec tail -80 {} \; || true
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
  launch_cmd=("$SUJI_BIN" dev)
  if [ -n "${SUJI_E2E_STRACE_DIR:-}" ] && command -v strace >/dev/null 2>&1; then
    mkdir -p "$SUJI_E2E_STRACE_DIR"
    launch_cmd=(strace -ff -tt -T -s 256 -o "$SUJI_E2E_STRACE_DIR/suji" "${launch_cmd[@]}")
  fi
  if [ "${SUJI_TRACE_IPC:-}" = "1" ]; then
    SUJI_TRACE_IPC=1 "${launch_cmd[@]}" > >(tee "$SUJI_LOG") 2>&1 &
  else
    "${launch_cmd[@]}" > >(tee "$SUJI_LOG") 2>&1 &
  fi
  SUJI_PID=$!

  e2e_wait_cef || exit 1
  sleep 3 # vite/CEF 안정화

  cd "$ROOT"
  SUJI_LOG="$SUJI_LOG" bun test "$test_file" --timeout 30000 2>&1 | tee -a "$SUJI_LOG"
}
