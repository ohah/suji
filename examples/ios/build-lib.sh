#!/usr/bin/env bash
# Suji 코어 + Rust/Go 정적 백엔드를 iOS 라이브러리로 빌드 + 스테이징.
# project.yml 이 Vendor/ 의 .a 3개를 링크한다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VENDOR="$HERE/Vendor"
mkdir -p "$VENDOR"

# 1. CEF 무관 코어 (libsuji_core.a)
cd "$REPO"
zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# 2. Rust 백엔드 정적 라이브러리 (suji_rs_* 고유 심볼)
cargo build --release --target aarch64-apple-ios \
  --manifest-path "$HERE/backends/rust/Cargo.toml"
cp "$HERE/backends/rust/target/aarch64-apple-ios/release/libsuji_rs_backend.a" \
   "$VENDOR/libsuji_rs_backend.a"

# 3. Go 백엔드 c-archive (suji_go_* 고유 심볼)
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
( cd "$HERE/backends/go" && \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
  CGO_CFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=15.0" \
  CGO_LDFLAGS="-isysroot $SDK -arch arm64" \
  go build -buildmode=c-archive -o "$VENDOR/libsuji_go_backend.a" . )

echo "staged:"
ls -1 "$VENDOR"
echo "next: (cd examples/ios && xcodegen generate && open SujiIOSExample.xcodeproj)"
