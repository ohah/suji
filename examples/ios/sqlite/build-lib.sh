#!/usr/bin/env bash
# SQLite 단독 iOS 예제 — 코어 + SQLite 정적 백엔드.
# 사용: ./build-lib.sh [sim|device]  (기본 sim — 디바이스 프로비저닝 불필요)
#
# 백엔드(.a, 벤더 sqlite3.c 포함)는 공용 examples/ios/backends/sqlite/
# build-lib.sh 재사용 — sysroot/cflags 로직 중복 없음(단일 출처).
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; SDK_NAME="iphonesimulator"; BK_MODE="ios-sim" ;;
  device) ZIG_T="aarch64-ios";           SDK_NAME="iphoneos";        BK_MODE="ios-device" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
rm -rf "$VENDOR"; mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# SQLite 백엔드(.a) — 공용 백엔드 build-lib.sh (벤더 sqlite3.c + iOS SDK sysroot).
bash "$BK/sqlite/build-lib.sh" "$BK_MODE" "$VENDOR"

echo "staged ($MODE):"; ls -1 "$VENDOR"
echo "next: xcodegen generate && xcodebuild -project SujiIOSSQLite.xcodeproj \\"
echo "        -scheme SujiIOSSQLite -sdk $SDK_NAME ARCHS=arm64 build"
