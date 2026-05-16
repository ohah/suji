#!/usr/bin/env bash
# 단일 버전 출처 = build.zig.zon 의 .version. release.yml / 로컬에서 사용.
# 사용: scripts/version.sh          → "0.1.0"
#       scripts/version.sh --check vX.Y.Z  → tag 와 일치 검증(불일치 exit 1)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZON="$HERE/../build.zig.zon"

VERSION="$(grep -oE '\.version = "[0-9]+\.[0-9]+\.[0-9]+"' "$ZON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$VERSION" ] || { echo "build.zig.zon 에서 .version 추출 실패" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  TAG="${2:?--check <tag> 필요}"
  EXPECT="v$VERSION"
  if [ "$TAG" != "$EXPECT" ]; then
    echo "버전 불일치: tag=$TAG, build.zig.zon=$EXPECT — .version 갱신 후 태그하세요" >&2
    exit 1
  fi
  echo "버전 일치: $TAG"
  exit 0
fi

echo "$VERSION"
