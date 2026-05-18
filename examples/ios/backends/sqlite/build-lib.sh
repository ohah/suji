#!/usr/bin/env bash
# 모바일 정적 SQLite 백엔드 (suji_sqlite_backend_*) 빌드.
#
# 데스크탑 plugins/sqlite 모바일 대응. 벤더 sqlite3.c(데스크탑과 단일 출처)를
# 정적 링크. 기존 모바일 백엔드와 동일하게 raw `zig build-lib` 사용
# (build.zig 불요). SQLite 는 C 라 타깃 libc 헤더 필요 — iOS=Xcode SDK
# sysroot, Android=NDK sysroot. (순수 Zig 백엔드와 달리 sysroot 필수.)
#
# 사용: ./build-lib.sh <host|ios-sim|ios-device|android> [out_dir]
set -euo pipefail

MODE="${1:?사용: $0 <host|ios-sim|ios-device|android> [out_dir]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VEN="$REPO/plugins/sqlite/zig/vendor"
OUT="${2:-$HERE/out}"
mkdir -p "$OUT"

# 데스크탑 plugins/sqlite/zig/build.zig 와 동일 컴파일 옵션.
CFLAGS=(-DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -DSQLITE_DEFAULT_FOREIGN_KEYS=1
        -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED
        -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_USE_URI=0 -std=c99)

TARGET_ARGS=()
case "$MODE" in
  host) ;;  # 호스트 기본 타깃 (libc 자동)
  ios-sim)
    SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    TARGET_ARGS=(-target aarch64-ios-simulator --sysroot "$SDK" -I"$SDK/usr/include") ;;
  ios-device)
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    TARGET_ARGS=(-target aarch64-ios --sysroot "$SDK" -I"$SDK/usr/include") ;;
  android)
    : "${ANDROID_NDK_HOME:?Android 빌드는 ANDROID_NDK_HOME 필요}"
    SYS="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
    TARGET_ARGS=(-target aarch64-linux-android --sysroot "$SYS"
                 -I"$SYS/usr/include" -I"$SYS/usr/include/aarch64-linux-android") ;;
  *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

zig build-lib -O ReleaseSmall -fPIC -lc "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" \
  -I"$VEN" \
  -femit-bin="$OUT/libsuji_sqlite_backend.a" --name suji_sqlite_backend \
  "$HERE/src/backend.zig" \
  -cflags "${CFLAGS[@]}" -- "$VEN/sqlite3.c"
rm -f "$OUT/libsuji_sqlite_backend.a.o"
echo "built ($MODE): $OUT/libsuji_sqlite_backend.a"
