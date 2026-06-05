#!/usr/bin/env bash
# iOS embedded CPython staging — BeeWare Python-Apple-support(PEP 730 공식 코드 기반)
# 의 iOS support tarball 을 ~/.suji/python-ios/<tag> 에 푼다(데스크탑 stage-python.sh
# 동형, libnode/CEF staging 패턴). examples/ios/backends/python/build-lib.sh 가 이
# 경로의 Python.xcframework 헤더로 backend.zig 를 컴파일하고, examples/ios/python
# 호스트가 framework + python-stdlib 를 앱 번들에 임베드한다.
#
# 멱등: Python.xcframework 가 이미 있으면 skip.
#
# env override:
#   PY_APPLE_TAG  (default 3.13-b13 — Python-Apple-support 릴리스 태그)
#
# 사용: ./scripts/stage-python-ios.sh

set -euo pipefail

PY_APPLE_TAG="${PY_APPLE_TAG:-3.13-b13}"
DEST="${HOME}/.suji/python-ios/${PY_APPLE_TAG}"
MARKER="${DEST}/Python.xcframework"

if [ -d "$MARKER" ]; then
  echo "[stage-python-ios] already staged: $MARKER"
  exit 0
fi

# 태그 3.13-b13 → 자산 Python-3.13-iOS-support.b13.tar.gz
BUILD_SUFFIX="${PY_APPLE_TAG##*-}"          # b13
PY_MINOR="${PY_APPLE_TAG%%-*}"               # 3.13
ASSET="Python-${PY_MINOR}-iOS-support.${BUILD_SUFFIX}.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${PY_APPLE_TAG}/${ASSET}"

echo "[stage-python-ios] downloading ${ASSET}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/py.tar.gz"

mkdir -p "$DEST"
tar -xzf "$tmp/py.tar.gz" -C "$DEST"

if [ ! -d "$MARKER" ]; then
  echo "[stage-python-ios] FAILED — Python.xcframework not found after extract" >&2
  exit 1
fi
echo "[stage-python-ios] staged: ${DEST}"
