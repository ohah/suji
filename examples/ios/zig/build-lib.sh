#!/usr/bin/env bash
# Zig 단독 iOS 예제 — 코어 + Zig 정적 백엔드.
# 사용: ./build-lib.sh [sim|device]  (기본 sim — 디바이스 프로비저닝 불필요)
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; SDK_NAME="iphonesimulator" ;;
  device) ZIG_T="aarch64-ios";           SDK_NAME="iphoneos" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
rm -rf "$VENDOR"; mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# Zig 백엔드 staticlib (suji_zig_* 고유 심볼). build.zig 없이 직접 build-lib.
zig build-lib -target "$ZIG_T" -O ReleaseSmall -lc \
  -femit-bin="$VENDOR/libsuji_zig_backend.a" \
  --name suji_zig_backend "$BK/zig/src/backend.zig"
rm -f "$VENDOR/libsuji_zig_backend.a.o"

echo "staged ($MODE):"; ls -1 "$VENDOR"
echo "next: xcodegen generate && xcodebuild -project SujiIOSZig.xcodeproj \\"
echo "        -scheme SujiIOSZig -sdk $SDK_NAME ARCHS=arm64 build"
