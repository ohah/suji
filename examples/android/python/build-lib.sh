#!/usr/bin/env bash
# Python 단독 Android 예제 — 코어(.so) + embedded CPython 백엔드(.a) + libpython.so
# (jniLibs) + 번들 stdlib(zip)/main.py(assets) 스테이징.
# 백엔드 소스는 examples/ios/backends/python 공유(타깃만 aarch64-linux-android).
# 사용: ./build-lib.sh [arm64-v8a]  (AVD 가 arm64 — x86_64 는 별도 CPython 빌드 필요)
# 사전: bash scripts/stage-python-android.sh (CPython NDK 크로스빌드 → ~/.suji/python-android)
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; NDK_PREFIX="aarch64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a (x86_64 는 CPython x86_64 크로스빌드 후속)"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$REPO/examples/ios/backends"
DEST="$HERE/cpp/libs/$ABI"
JNILIBS="$HERE/jniLibs/$ABI"
ASSETS="$HERE/assets"
API=26
PYROOT="$HOME/.suji/python-android/3.13.13/$ABI"
PYINC="$PYROOT/include/python3.13"
PYLIB="$PYROOT/lib"

[ -d "$PYINC" ] || { echo "Android CPython 미staging: $PYROOT — 먼저 bash scripts/stage-python-android.sh" >&2; exit 1; }

mkdir -p "$DEST" "$JNILIBS" "$ASSETS"
rm -f "$DEST/libsuji_core.a"

NDK="${ANDROID_NDK_HOME:-}"
[ -z "$NDK" ] && NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
SYSROOT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"

# 1. 코어 동적 .so (zig std Io.Threaded LE-TLS↔JNI -shared 회피 — android zig 동형).
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

# 2. Python 백엔드 .a — backend_android.c 를 NDK clang 으로 컴파일. ⚠️ zig
#    @cImport(Python.h) translate-c 가 NDK bionic(배열 nullability/__overloadable
#    ioctl)을 못 풀어, android 는 iOS backend.zig 동일 로직을 C 로 두고 NDK clang
#    (real clang — bionic 무사)으로 빌드한다. Py* 심볼은 libpython.so 가 앱 링크 해소.
TOOLBIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CLANG="$TOOLBIN/${NDK_PREFIX}${API}-clang"
"$CLANG" -c -fPIC -O2 -I"$PYINC" -I"$REPO/include" \
  "$BK/python/src/backend_android.c" -o "$DEST/backend_android.o"
"$TOOLBIN/llvm-ar" rcs "$DEST/libsuji_python_backend.a" "$DEST/backend_android.o"
rm -f "$DEST/backend_android.o"

# 3. libpython3.13.so → jniLibs (런타임 로드 + 백엔드 Py* 링크 해소).
cp "$PYLIB/libpython3.13.so" "$JNILIBS/libpython3.13.so"

# 4. stdlib → assets/python-stdlib.zip (lib/python3.13/...). 부피 prune(test/idlelib/
#    ensurepip/tkinter/__pycache__) — APK 크기/추출 속도. zip 내 경로 lib/python3.13/*.
rm -f "$ASSETS/python-stdlib.zip"
( cd "$PYROOT" && zip -q -r -X "$ASSETS/python-stdlib.zip" lib/python3.13 \
    -x '*/test/*' '*/tests/*' '*/__pycache__/*' '*/idlelib/*' '*/ensurepip/*' \
       '*/turtledemo/*' '*/tkinter/*' '*/lib2to3/*' '*.pyc' )

# 5. main.py → assets (엔트리; MainActivity 가 filesDir 로 복사).
cp "$BK/python/main.py" "$ASSETS/main.py"

echo "staged ($ABI):"; ls -1 "$DEST" "$JNILIBS"; du -sh "$ASSETS/python-stdlib.zip"
echo "next: (cd examples/android/python && ./gradlew :app:assembleDebug)"
