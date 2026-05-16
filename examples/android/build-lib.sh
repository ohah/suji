#!/usr/bin/env bash
# Suji 코어 + Rust/Go 정적 백엔드를 Android 라이브러리로 빌드 + ABI별 스테이징.
# CMakeLists.txt 가 app/src/main/cpp/libs/<abi>/libsuji_*.a 를 IMPORTED 로 링크.
#
# iOS(examples/ios/backends/{rust,go})와 동일 백엔드 소스를 재사용 — 타깃만 다름.
# 사용: ./build-lib.sh [abi]   (abi: arm64-v8a(기본) | x86_64)
# x86_64(에뮬레이터)로 빌드 시 app/build.gradle 의 abiFilters 에 "x86_64" 추가 필요.
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; RUST_TARGET="aarch64-linux-android"; NDK_PREFIX="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android";  RUST_TARGET="x86_64-linux-android";  NDK_PREFIX="x86_64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a | x86_64 (입력: $ABI)"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BK="$REPO/examples/ios/backends" # iOS와 공유하는 백엔드 소스
DEST="$HERE/app/src/main/cpp/libs/$ABI"
API=26 # app/build.gradle minSdk 와 일치
mkdir -p "$DEST"

# NDK 툴체인 탐색 (ANDROID_NDK_HOME → SDK ndk/* 폴백)
NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"; fi
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
# NDK 는 Apple Silicon 에서도 prebuilt 디렉토리명을 darwin-x86_64 로 유지(r23+).
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CLANG="$TOOLCHAIN/${NDK_PREFIX}${API}-clang"

# 1. CEF 무관 코어
( cd "$REPO" && zig build lib -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$DEST/libsuji_core.a"

# 2. Rust 백엔드 (suji_rs_* 고유 심볼) — NDK clang 을 링커로
RUST_ENV_VAR="CARGO_TARGET_$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER"
env "$RUST_ENV_VAR=$CLANG" "CC_${RUST_TARGET}=$CLANG" \
  cargo build --release --target "$RUST_TARGET" --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/$RUST_TARGET/release/libsuji_rs_backend.a" "$DEST/libsuji_rs_backend.a"

# 3. Go 백엔드 — Android 는 c-archive 미지원이므로 c-shared(.so).
#    Gradle 이 jniLibs/<abi>/ 의 .so 를 자동 패키징, CMake 가 SHARED IMPORTED 링크.
JNILIBS="$HERE/app/src/main/jniLibs/$ABI"
mkdir -p "$JNILIBS"
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=android GOARCH="$( [ "$ABI" = arm64-v8a ] && echo arm64 || echo amd64 )" \
  CC="$CLANG" go build -buildmode=c-shared -o "$JNILIBS/libsuji_go_backend.so" . )

echo "staged ($ABI):"
ls -1 "$DEST"
echo "jniLibs/$ABI:"; ls -1 "$JNILIBS"
echo "next: (cd examples/android && ./gradlew installDebug)"
