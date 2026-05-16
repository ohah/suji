#!/usr/bin/env bash
# Go 단독 iOS 예제 — 코어 + Go c-archive 정적 라이브러리.
# 사용: ./build-lib.sh [sim|device]  (기본 sim — 디바이스 프로비저닝 불필요)
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; SDK_NAME="iphonesimulator"; MIN="-mios-simulator-version-min=15.0" ;;
  device) ZIG_T="aarch64-ios";           SDK_NAME="iphoneos";        MIN="-miphoneos-version-min=15.0" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
rm -rf "$VENDOR"; mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK_NAME" --find clang)"
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
  CGO_CFLAGS="-isysroot $SDK -arch arm64 $MIN" \
  CGO_LDFLAGS="-isysroot $SDK -arch arm64" \
  go build -buildmode=c-archive -o "$VENDOR/libsuji_go_backend.a" . )

echo "staged ($MODE):"; ls -1 "$VENDOR"
echo "next: xcodegen generate && xcodebuild -project SujiIOSGo.xcodeproj \\"
echo "        -scheme SujiIOSGo -sdk $SDK_NAME ARCHS=arm64 build"
