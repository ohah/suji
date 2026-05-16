#!/usr/bin/env bash
# Rust 단독 iOS 예제 — 코어 + Rust 정적 라이브러리만 스테이징.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

cargo build --release --target aarch64-apple-ios --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/aarch64-apple-ios/release/libsuji_rs_backend.a" "$VENDOR/libsuji_rs_backend.a"

echo "staged:"; ls -1 "$VENDOR"
echo "next: (cd examples/ios/rust && xcodegen generate && open SujiIOSRust.xcodeproj)"
