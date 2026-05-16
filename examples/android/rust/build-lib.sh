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
JNILIBS="$HERE/jniLibs/$ABI"
API=26
mkdir -p "$DEST" "$JNILIBS"
rm -f "$DEST/libsuji_core.a"   # 코어는 이제 .so(jniLibs) — 이전 .a 잔존 제거

NDK="${ANDROID_NDK_HOME:-}"
[ -z "$NDK" ] && NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
CLANG="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/${NDK_PREFIX}${API}-clang"

# 코어는 동적 .so — 정적 .a 의 zig LE-TLS 가 JNI -shared 비호환(R_AARCH64_
# TLSLE_*). .so 는 TLSDESC. zig 가 Android Bionic 미제공이라 NDK sysroot 를
# --libc 로 공급. Go .so 와 동일하게 jniLibs 패키징(런타임 DT_NEEDED 해소).
SYSROOT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
LIBC_TXT="$(mktemp)"
cat > "$LIBC_TXT" <<EOF2
include_dir=$SYSROOT/usr/include
sys_include_dir=$SYSROOT/usr/include
crt_dir=$SYSROOT/usr/lib/$NDK_PREFIX/$API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF2
( cd "$REPO" && zig build lib -Dlib-dynamic -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSmall --libc "$LIBC_TXT" )
cp "$REPO/zig-out/lib/libsuji_core.so" "$JNILIBS/libsuji_core.so"
rm -f "$LIBC_TXT"

RUST_ENV_VAR="CARGO_TARGET_$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER"
env "$RUST_ENV_VAR=$CLANG" "CC_${RUST_TARGET}=$CLANG" \
  cargo build --release --target "$RUST_TARGET" --manifest-path "$BK/rust/Cargo.toml"
cp "$BK/rust/target/$RUST_TARGET/release/libsuji_rs_backend.a" "$DEST/libsuji_rs_backend.a"

echo "staged ($ABI):"; ls -1 "$DEST"
echo "next: (cd examples/android/rust && ./gradlew installDebug  # 또는 Android Studio)"
