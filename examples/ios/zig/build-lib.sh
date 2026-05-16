#!/usr/bin/env bash
# Zig 단독 iOS 예제 — 코어 + Zig 정적 백엔드.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BK="$HERE/../backends"
VENDOR="$HERE/Vendor"
mkdir -p "$VENDOR"

( cd "$REPO" && zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe )
cp "$REPO/zig-out/lib/libsuji_core.a" "$VENDOR/libsuji_core.a"

# Zig 백엔드 staticlib (suji_zig_* 고유 심볼). build.zig 없이 직접 build-lib.
zig build-lib -target aarch64-ios -O ReleaseSafe -lc \
  -femit-bin="$VENDOR/libsuji_zig_backend.a" \
  --name suji_zig_backend "$BK/zig/src/backend.zig"
rm -f "$VENDOR/libsuji_zig_backend.a.o"

echo "staged:"; ls -1 "$VENDOR"
echo "next: (cd examples/ios/zig && xcodegen generate && open SujiIOSZig.xcodeproj)"
