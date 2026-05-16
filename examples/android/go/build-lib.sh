#!/usr/bin/env bash
# Go 단독 Android 예제 — 코어(.a) + Go(.so c-shared) 스테이징.
# 백엔드 소스는 examples/ios/backends 공유. 사용: ./build-lib.sh [arm64-v8a|x86_64]
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; NDK_PREFIX="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android";  NDK_PREFIX="x86_64-linux-android" ;;
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
CLANG="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/${NDK_PREFIX}${API}-clang"

# 코어 동적 .so (zig LE-TLS↔JNI -shared 회피) — NDK sysroot 를 --libc 로 공급.
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

# Go c-shared 는 SONAME 미설정 → DT_NEEDED 절대경로화 → 디바이스 dlopen 실패.
# -Wl,-soname 으로 basename SONAME 주입.
( cd "$BK/go" && \
  CGO_ENABLED=1 GOOS=android GOARCH="$( [ "$ABI" = arm64-v8a ] && echo arm64 || echo amd64 )" \
  CC="$CLANG" go build -buildmode=c-shared \
  -ldflags="-extldflags=-Wl,-soname,libsuji_go_backend.so" \
  -o "$JNILIBS/libsuji_go_backend.so" . )

echo "staged ($ABI):"; ls -1 "$DEST" "$JNILIBS"
echo "next: (cd examples/android/go && ./gradlew installDebug  # 또는 Android Studio)"
