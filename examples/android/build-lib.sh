#!/usr/bin/env bash
# Suji 코어를 Android 정적 라이브러리로 빌드 + ABI별 스테이징.
# CMakeLists.txt 가 app/src/main/cpp/libs/<abi>/libsuji_core.a 를 IMPORTED 로 링크.
#
# 사용: ./build-lib.sh [abi]   (abi: arm64-v8a(기본) | x86_64)
set -euo pipefail

ABI="${1:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a | x86_64 (입력: $ABI)"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

cd "$REPO"
zig build lib -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe

DEST="$HERE/app/src/main/cpp/libs/$ABI"
mkdir -p "$DEST"
cp "$REPO/zig-out/lib/libsuji_core.a" "$DEST/libsuji_core.a"

echo "staged: examples/android/app/src/main/cpp/libs/$ABI/libsuji_core.a"
echo "next: (cd examples/android && ./gradlew installDebug)"
