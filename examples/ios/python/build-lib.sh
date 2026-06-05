#!/usr/bin/env bash
# Python 단독 iOS 예제 — 코어 + embedded CPython 정적 백엔드 + Python.xcframework
# + 번들 stdlib + main.py 스테이징.
# 사용: ./build-lib.sh [sim|device]  (기본 sim — 디바이스 프로비저닝 불필요)
# 사전: bash scripts/stage-python-ios.sh (Python.xcframework + stdlib 다운로드)
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; SDK_NAME="iphonesimulator"; BK_MODE="ios-sim"; SLICE="ios-arm64_x86_64-simulator"; DYNLOAD="lib-arm64" ;;
  device) ZIG_T="aarch64-ios";           SDK_NAME="iphoneos";        BK_MODE="ios-device"; SLICE="ios-arm64";             DYNLOAD="lib" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
PY_APPLE_TAG="${PY_APPLE_TAG:-3.13-b13}"
PYX="$HOME/.suji/python-ios/$PY_APPLE_TAG/Python.xcframework"

[ -d "$PYX" ] || { echo "Python.xcframework 없음 — 먼저 bash scripts/stage-python-ios.sh" >&2; exit 1; }

rm -rf "$VENDOR"; mkdir -p "$VENDOR"

# 1. 코어 (.a)
( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# 2. Python 백엔드 (.a) — 공용 backends/python/build-lib.sh (xcframework 헤더로 컴파일).
bash "$BK/python/build-lib.sh" "$BK_MODE" "$VENDOR"

# 3. Python.xcframework — 링크 + 임베드(project.yml dependency).
cp -R "$PYX" "$VENDOR/Python.xcframework"

# 4. 번들 PYTHONHOME — <bundle>/python/lib/python3.13 = pure-python stdlib +
#    arch lib-dynload(.so C 확장: _json 등). PYTHONHOME=<resourcePath>/python.
mkdir -p "$VENDOR/python/lib"
cp -R "$PYX/lib/python3.13" "$VENDOR/python/lib/python3.13"
DYNLOAD_SRC="$PYX/$SLICE/$DYNLOAD/python3.13/lib-dynload"
if [ -d "$DYNLOAD_SRC" ]; then
  cp -R "$DYNLOAD_SRC" "$VENDOR/python/lib/python3.13/lib-dynload"
fi

# 5. main.py (엔트리) — <resourcePath>/main.py.
cp "$BK/python/main.py" "$VENDOR/main.py"

echo "staged ($MODE):"; ls -1 "$VENDOR"
echo "next: xcodegen generate && xcodebuild -project SujiIOSPython.xcodeproj \\"
echo "        -scheme SujiIOSPython -sdk $SDK_NAME ARCHS=arm64 build"
