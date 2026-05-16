#!/usr/bin/env bash
# Rust 단독 iOS 예제 — 코어 + Rust 정적 라이브러리.
# 사용: ./build-lib.sh [sim|device]  (기본 sim — 디바이스 프로비저닝 불필요)
set -euo pipefail

MODE="${1:-sim}"
case "$MODE" in
  sim)    ZIG_T="aarch64-ios-simulator"; RUST_T="aarch64-apple-ios-sim" ;;
  device) ZIG_T="aarch64-ios";           RUST_T="aarch64-apple-ios" ;;
  *) echo "사용: $0 [sim|device]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
rm -rf "$VENDOR"; mkdir -p "$VENDOR"   # 모드 전환 시 이전 플랫폼 .a 잔존 방지

# ReleaseSmall: 임베드 모바일에 적합(작고, 패닉 스택트레이스 dyld 의존 제거 —
# 시뮬레이터 링크에 필수).
( cd "$REPO" && zig build lib -Dtarget="$ZIG_T" -Doptimize=ReleaseSmall )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

cargo build --release --target "$RUST_T" --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/$RUST_T/release/libsuji_rs_backend.a" "$VENDOR/libsuji_rs_backend.a"

echo "staged ($MODE):"; ls -1 "$VENDOR"
SDK_NAME=$([ "$MODE" = sim ] && echo iphonesimulator || echo iphoneos)
echo "next: xcodegen generate && xcodebuild -project SujiIOSRust.xcodeproj \\"
echo "        -scheme SujiIOSRust -sdk $SDK_NAME ARCHS=arm64 build"
