#!/usr/bin/env bash
# Packaged embedded-CPython e2e 가드.
#
# dev(run-python-e2e.sh)는 ~/.suji/python 또는 zig-out/bin/python 을 PYTHONHOME 으로
# 쓰지만, packaged 는 `suji build` 가 python313.dll + python/{Lib,DLLs} 를 번들하고
# 런타임이 sentinel-gated `<exe_dir>/python` 으로 해석한다. 이 경로가 깨지면 packaged
# python 앱이 init 실패("not available")하므로 — dev 통과만으론 못 잡는다 — 여기서
# 실제 `suji build` → 패키지 exe 실행 → 임베드 CPython init + frontend bind 를 검증한다.
#
# 사용: bash tests/e2e/run-python-packaged.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXAMPLE="$ROOT/examples/python-backend"
LOG="${SUJI_LOG:-/tmp/suji-e2e-python-packaged.log}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WIN=1 ;;
  *) WIN=0 ;;
esac
SUJI_BIN="$ROOT/zig-out/bin/suji"
[ "$WIN" = 1 ] && SUJI_BIN="${SUJI_BIN}.exe"

cleanup() {
  if [ "$WIN" = 1 ]; then
    powershell -NoProfile -ExecutionPolicy Bypass -Command \
      'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*Suji Python Backend*" -or $_.CommandLine -like "*node_modules*vite*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' \
      >/dev/null 2>&1 || true
  else
    pkill -9 -f "Suji Python Backend" 2>/dev/null || true
    pkill -9 -f "node.*vite" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[pkg-py] staging portable CPython (idempotent) + building (python auto-enable)"
bash "$ROOT/scripts/stage-python.sh"
( cd "$ROOT" && zig build )

echo "[pkg-py] installing python-backend frontend deps"
( cd "$EXAMPLE/frontend" && bun install >/dev/null 2>&1 )

echo "[pkg-py] suji build (package)"
# stale 패키지 출력 제거 — 이전 빌드의 잔존 디렉토리를 잘못 선택하지 않도록(전부 gitignored 산출물).
rm -rf "$EXAMPLE"/*-windows-x64 "$EXAMPLE"/*-windows-x64.zip \
       "$EXAMPLE"/*-linux-x64 "$EXAMPLE"/*-linux-x64.tar.gz \
       "$EXAMPLE"/*.app 2>/dev/null || true
( cd "$EXAMPLE" && "$SUJI_BIN" build )

# 패키지 디렉토리 + exe 탐색 — suji build 출력은 OS마다 다르다:
#   Windows: <name>-<ver>-windows-x64/  + .exe                 (packageWindows)
#   Linux:   <name>-<ver>-linux-x64/    + bin/<name>            (packageLinux stage dir, 아카이브 후 잔존)
#   macOS:   <name>.app                 + Contents/MacOS/<name> (bundle_macos.createBundle)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    PKG="$(ls -d "$EXAMPLE"/*-windows-x64 2>/dev/null | head -1 || true)"
    [ -n "$PKG" ] || { echo "FAIL: Windows package dir (*-windows-x64) not found under $EXAMPLE"; ls "$EXAMPLE"; exit 1; }
    EXE="$(ls "$PKG"/*.exe 2>/dev/null | grep -ivE "subprocess|crashpad" | head -1 || true)"
    ;;
  Darwin)
    PKG="$(ls -d "$EXAMPLE"/*.app 2>/dev/null | head -1 || true)"
    [ -n "$PKG" ] || { echo "FAIL: macOS package (*.app) not found under $EXAMPLE"; ls "$EXAMPLE"; exit 1; }
    # BSD find: -perm +111 = any exec bit. Contents/MacOS 의 main 바이너리(헬퍼 제외).
    EXE="$(find "$PKG/Contents/MacOS" -maxdepth 1 -type f -perm +111 2>/dev/null | grep -ivE "Helper|crashpad" | head -1 || true)"
    ;;
  *)
    PKG="$(ls -d "$EXAMPLE"/*-linux-x64 2>/dev/null | head -1 || true)"
    [ -n "$PKG" ] || { echo "FAIL: Linux package dir (*-linux-x64) not found under $EXAMPLE"; ls "$EXAMPLE"; exit 1; }
    EXE="$(find "$PKG/bin" -maxdepth 1 -type f -perm -u+x 2>/dev/null | grep -ivE "Helper|crashpad|\.so" | head -1 || true)"
    ;;
esac
[ -n "$EXE" ] || { echo "FAIL: packaged executable not found in $PKG"; ls "$PKG"; exit 1; }

echo "[pkg-py] launching packaged app: $EXE"
rm -f "$LOG"
cleanup
sleep 1
# CWD=예제 source dir 에서 패키지 exe 실행 — config(suji.json)/dist 는 source 에서
# 읽지만(packaged 앱의 config-portability 는 별개·기존 동작), 임베드 python 은
# exe-dir/.suji-packaged sentinel 로 **패키지 번들**(python313.dll + python/{Lib,DLLs}
# + backends/python)에서 해석된다. 즉 이 가드는 packaged python 번들을 검증.
# GUI 앱이라 자체 종료 안 하므로 timeout 으로 종료.
( cd "$EXAMPLE" && SUJI_CEF_CI=1 timeout 35 "$EXE" > "$LOG" 2>&1 || true )

echo "[pkg-py] asserting bundled CPython init + frontend bind"
fail=0
if grep -q "\[suji-python\] started" "$LOG"; then
  echo "  ✓ embedded CPython initialized + main.py ran (bundled stdlib)"
else
  echo "  ✗ embedded python did NOT start (PYTHONHOME/번들 stdlib 해석 실패?)"; fail=1
fi
if grep -q "window.__suji__ bound" "$LOG"; then
  echo "  ✓ renderer bound window.__suji__ (frontend loaded from bundle)"
else
  echo "  ✗ frontend did NOT bind window.__suji__"; fail=1
fi
if grep -qiE "Python backend not available" "$LOG"; then
  echo "  ✗ runtime reported 'Python backend not available'"; fail=1
fi

if [ "$fail" != 0 ]; then
  echo "=== packaged run log (tail) ==="; tail -50 "$LOG" || true
  exit 1
fi
echo "[pkg-py] PASS — packaged embedded CPython works end-to-end"
