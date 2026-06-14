#!/usr/bin/env bash
# Node 단독 Android 예제 — 코어(.so) + libnode.so(jniLibs) + node api headers
# (cpp/node-include, CMake 가 bridge.cc 컴파일에 사용) + main.js(assets) 스테이징.
# bridge.cc 는 데스크톱과 동일 — CMake(externalNativeBuild)가 NDK clang++ 로 컴파일.
# 사전: bash scripts/stage-node-android.sh (libnode Android 크로스빌드 → ~/.suji/node-android)
#   ⚠️ libnode 크로스빌드는 V8 가 host 를 Linux 로 가정 → CI(ubuntu)에서 수행해야
#      안정적(macOS host 는 host build 가 V8 가정과 어긋나 framework/SDK 패치 다발).
# 사용: ./build-lib.sh [arm64-v8a]
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; NDK_PREFIX="aarch64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
JNILIBS="$HERE/jniLibs/$ABI"
ASSETS="$HERE/assets"
API=26
NODE_VERSION="${NODE_VERSION:-24.14.1}"
NODEROOT="$HOME/.suji/node-android/$NODE_VERSION/$ABI"

[ -f "$NODEROOT/lib/libnode.so" ] || { echo "Android libnode 미staging: $NODEROOT — 먼저 bash scripts/stage-node-android.sh" >&2; exit 1; }

mkdir -p "$JNILIBS" "$ASSETS"
rm -rf "$HERE/cpp/node-include"

NDK="${ANDROID_NDK_HOME:-}"
[ -z "$NDK" ] && NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | tail -1)"
[ -n "$NDK" ] || { echo "NDK 미발견 — ANDROID_NDK_HOME 설정 필요"; exit 1; }
HOST="$(ls -d "$NDK/toolchains/llvm/prebuilt/"* 2>/dev/null | head -1)"
SYSROOT="$HOST/sysroot"

# 1. 코어 동적 .so (python/multi 변형 동일 — zig std Io.Threaded LE-TLS↔JNI 회피).
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

# 2. libnode.so → jniLibs (런타임 로드 + bridge V8/node 심볼 링크 해소).
cp "$NODEROOT/lib/libnode.so" "$JNILIBS/libnode.so"

# 3. node api headers → cpp/node-include (CMake 가 bridge.cc 컴파일에 사용).
cp -R "$NODEROOT/include" "$HERE/cpp/node-include"

# 4. main.js → assets (엔트리; MainActivity 가 filesDir 로 복사 후 등록).
cp "$HERE/main.js" "$ASSETS/main.js"

echo "staged ($ABI):"; ls -1 "$JNILIBS"; ls -1 "$ASSETS"
echo "next: (cd examples/android/node && ./gradlew :app:assembleDebug)"
