#!/usr/bin/env bash
# Suji 코어를 iOS 정적 라이브러리로 빌드 + 스테이징.
# project.yml 이 Vendor/libsuji_core.a 를 링크한다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

cd "$REPO"
zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe

mkdir -p "$HERE/Vendor"
cp "$REPO/zig-out/lib/libsuji_core.a" "$HERE/Vendor/libsuji_core.a"

echo "staged: examples/ios/Vendor/libsuji_core.a"
echo "next: (cd examples/ios && xcodegen generate && open SujiIOSExample.xcodeproj)"
