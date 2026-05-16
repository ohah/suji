#!/usr/bin/env bash
# Zig 단독 Android 예제 — 코어(.a) + Zig 백엔드(.a) 정적 스테이징.
# 백엔드 소스는 examples/ios/backends/zig 공유. 사용: ./build-lib.sh [arm64-v8a|x86_64]
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a | x86_64"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$REPO/examples/ios/backends"
DEST="$HERE/cpp/libs/$ABI"
JNILIBS="$HERE/jniLibs/$ABI"
API=26
mkdir -p "$DEST" "$JNILIBS"
rm -f "$DEST/libsuji_core.a"   # 코어는 이제 .so(jniLibs)

NDK="${ANDROID_NDK_HOME:-}"
[ -z "$NDK" ] && NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
NDK_PREFIX=$([ "$ABI" = arm64-v8a ] && echo aarch64-linux-android || echo x86_64-linux-android)

# 코어 동적 .so (zig std Io.Threaded LE-TLS↔JNI -shared 회피) — NDK libc 공급.
# (zig 백엔드 .a 는 Io.Threaded 미사용이라 정적 링크 OK.)
SYSROOT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
LIBC_TXT="$(mktemp)"; trap 'rm -f "$LIBC_TXT"' EXIT
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

# Zig 백엔드 staticlib (suji_zig_* 고유 심볼). build.zig 없이 직접 build-lib.
zig build-lib -target "$ZIG_TARGET" -O ReleaseSmall -fPIC -lc \
  -femit-bin="$DEST/libsuji_zig_backend.a" \
  --name suji_zig_backend "$BK/zig/src/backend.zig"
rm -f "$DEST/libsuji_zig_backend.a.o"

echo "staged ($ABI):"; ls -1 "$DEST"
echo "next: (cd examples/android/zig && ./gradlew installDebug  # 또는 Android Studio)"
