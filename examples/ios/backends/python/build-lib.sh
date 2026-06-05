#!/usr/bin/env bash
# 모바일 정적 embedded CPython 백엔드 (suji_python_backend_*) 빌드.
#
# 데스크탑 src/platform/python.zig 모바일 대응. backend.zig 는 Python.xcframework
# 헤더로 컴파일만 한다 — libpython 심볼(Py*)과 suji_core_* 는 정적 .a 에 undefined
# 로 남고 앱 링크 단계에서 Python.framework + libsuji_core.a 가 해소(sqlite 는
# sqlite3.c 를 .a 에 포함하지만 Python 은 외부 framework 라 헤더만 필요).
#
# 사용: ./build-lib.sh <ios-sim|ios-device> [out_dir]
# 사전: bash scripts/stage-python-ios.sh (Python.xcframework staging)
set -euo pipefail

MODE="${1:?사용: $0 <ios-sim|ios-device> [out_dir]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${2:-$HERE/out}"
mkdir -p "$OUT"

PY_APPLE_TAG="${PY_APPLE_TAG:-3.13-b13}"
PYROOT="$HOME/.suji/python-ios/$PY_APPLE_TAG/Python.xcframework"

TARGET_ARGS=()
case "$MODE" in
  ios-sim)
    SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    INC="$PYROOT/ios-arm64_x86_64-simulator/include/python3.13"
    TARGET_ARGS=(-target aarch64-ios-simulator --sysroot "$SDK" -I"$SDK/usr/include") ;;
  ios-device)
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    INC="$PYROOT/ios-arm64/include/python3.13"
    TARGET_ARGS=(-target aarch64-ios --sysroot "$SDK" -I"$SDK/usr/include") ;;
  *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

[ -d "$INC" ] || { echo "python iOS 헤더 없음: $INC — 먼저 bash scripts/stage-python-ios.sh" >&2; exit 1; }

zig build-lib -O ReleaseSmall -fPIC -lc "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" \
  -I"$INC" \
  -femit-bin="$OUT/libsuji_python_backend.a" --name suji_python_backend \
  "$HERE/src/backend.zig"
rm -f "$OUT/libsuji_python_backend.a.o"
echo "built ($MODE): $OUT/libsuji_python_backend.a"
