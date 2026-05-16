#!/usr/bin/env bash
# Rust 단독 Android 예제 — 코어 + Rust(.a) 정적 스테이징.
# 백엔드 소스는 examples/ios/backends 공유. 사용: ./build-lib.sh [arm64-v8a|x86_64]
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; RUST_TARGET="aarch64-linux-android"; NDK_PREFIX="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android";  RUST_TARGET="x86_64-linux-android";  NDK_PREFIX="x86_64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a | x86_64"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$REPO/examples/ios/backends"
DEST="$HERE/cpp/libs/$ABI"
API=26
mkdir -p "$DEST"

NDK="${ANDROID_NDK_HOME:-}"
[ -z "$NDK" ] && NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
CLANG="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/${NDK_PREFIX}${API}-clang"

( cd "$REPO" && zig build lib -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$DEST/libsuji_core.a"

RUST_ENV_VAR="CARGO_TARGET_$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER"
env "$RUST_ENV_VAR=$CLANG" "CC_${RUST_TARGET}=$CLANG" \
  cargo build --release --target "$RUST_TARGET" --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/$RUST_TARGET/release/libsuji_rs_backend.a" "$DEST/libsuji_rs_backend.a"

echo "staged ($ABI):"; ls -1 "$DEST"
echo "next: (cd examples/android/rust && ./gradlew installDebug  # 또는 Android Studio)"
