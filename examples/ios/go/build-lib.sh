#!/usr/bin/env bash
# Go 단독 iOS 예제 — 코어 + Go c-archive 정적 라이브러리.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
  CGO_CFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=15.0" \
  CGO_LDFLAGS="-isysroot $SDK -arch arm64" \
  go build -buildmode=c-archive -o "$VENDOR/libsuji_go_backend.a" . )

echo "staged:"; ls -1 "$VENDOR"
echo "next: (cd examples/ios/go && xcodegen generate && open SujiIOSGo.xcodeproj)"
