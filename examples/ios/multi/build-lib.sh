#!/usr/bin/env bash
# 멀티 백엔드 iOS 예제 — 코어 + Rust + Go 정적 라이브러리 스테이징.
# 백엔드 소스는 examples/ios/backends 공유(언어별 변형이 동일 소스 재사용).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
mkdir -p "$VENDOR"

# 1. CEF 무관 코어
( cd "$REPO" && zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# 2. Rust 백엔드 (suji_rs_* 정적 .a)
cargo build --release --target aarch64-apple-ios --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/aarch64-apple-ios/release/libsuji_rs_backend.a" "$VENDOR/libsuji_rs_backend.a"

# 3. Go 백엔드 (suji_go_* c-archive .a — iOS 는 c-archive 지원)
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
  CGO_CFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=15.0" \
  CGO_LDFLAGS="-isysroot $SDK -arch arm64" \
  go build -buildmode=c-archive -o "$VENDOR/libsuji_go_backend.a" . )

echo "staged:"; ls -1 "$VENDOR"
echo "next: (cd examples/ios/multi && xcodegen generate && open SujiIOSMulti.xcodeproj)"
