#!/usr/bin/env bash
# 멀티 백엔드 iOS 예제 — 코어 + Rust + Go 정적 라이브러리 스테이징.
# 백엔드 소스는 examples/ios/backends 공유(언어별 변형이 동일 소스 재사용).
#
# 사용: ./build-lib.sh [sim|device]   (기본 sim — 디바이스 프로비저닝 불필요)
#   sim    : iOS Simulator (arm64) — xcodebuild -sdk iphonesimulator 와 짝
#   device : 실기기 (arm64 iphoneos)
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; RUST_T="aarch64-apple-ios-sim"; SDK_NAME="iphonesimulator"; MIN="-mios-simulator-version-min=15.0" ;;
  device) ZIG_T="aarch64-ios";           RUST_T="aarch64-apple-ios";     SDK_NAME="iphoneos";        MIN="-miphoneos-version-min=15.0" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
rm -rf "$VENDOR"; mkdir -p "$VENDOR"   # 모드 전환 시 이전 플랫폼 .a 잔존 방지

# 1. CEF 무관 코어
( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# 2. Rust 백엔드 (suji_rs_* 정적 .a)
cargo build --release --target "$RUST_T" --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/$RUST_T/release/libsuji_rs_backend.a" "$VENDOR/libsuji_rs_backend.a"

# 3. Go 백엔드 (suji_go_* c-archive .a) — SDK sysroot 으로 sim/device 구분
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK_NAME" --find clang)"
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
  CGO_CFLAGS="-isysroot $SDK -arch arm64 $MIN" \
  CGO_LDFLAGS="-isysroot $SDK -arch arm64" \
  go build -buildmode=c-archive -o "$VENDOR/libsuji_go_backend.a" . )

echo "staged ($MODE):"; ls -1 "$VENDOR"
echo "next: xcodegen generate && xcodebuild -project SujiIOSMulti.xcodeproj \\"
echo "        -scheme SujiIOSMulti -sdk $SDK_NAME build"
