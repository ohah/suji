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
mkdir -p "$DEST"

( cd "$REPO" && zig build lib -Dtarget="$ZIG_TARGET" -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$DEST/libsuji_core.a"

# Zig 백엔드 staticlib (suji_zig_* 고유 심볼). build.zig 없이 직접 build-lib.
zig build-lib -target "$ZIG_TARGET" -O ReleaseSafe -lc \
  -femit-bin="$DEST/libsuji_zig_backend.a" \
  --name suji_zig_backend "$BK/zig/src/backend.zig"
rm -f "$DEST/libsuji_zig_backend.a.o"

echo "staged ($ABI):"; ls -1 "$DEST"
echo "next: (cd examples/android/zig && ./gradlew installDebug  # 또는 Android Studio)"
