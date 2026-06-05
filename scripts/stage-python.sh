#!/usr/bin/env bash
# Embedded CPython staging — python-build-standalone(astral) `install_only`
# portable CPython 을 ~/.suji/python/<ver> 에 푼다(libnode staging 패턴 동형).
# build.zig 가 이 경로의 libpython 존재를 auto-detect → python_enabled.
#
# 멱등: libpython 이 이미 있으면 skip. CI/release/e2e 가 호출.
#
# env override:
#   PYTHON_VERSION   (default 3.13.13)
#   PYTHON_PBS_TAG   (default 20260602 — python-build-standalone 릴리스 태그)
#   PYTHON_TRIPLE    (미지정 시 uname 으로 추론)
#
# 사용: ./scripts/stage-python.sh

set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.13.13}"
PYTHON_PBS_TAG="${PYTHON_PBS_TAG:-20260602}"
DEST="${HOME}/.suji/python/${PYTHON_VERSION}"

# 플랫폼 triple 추론 (python-build-standalone install_only 명명 규칙).
if [ -z "${PYTHON_TRIPLE:-}" ]; then
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) PYTHON_TRIPLE="aarch64-apple-darwin" ;;
        x86_64) PYTHON_TRIPLE="x86_64-apple-darwin" ;;
        *) echo "unsupported macOS arch: $arch" >&2; exit 1 ;;
      esac ;;
    Linux)
      case "$arch" in
        x86_64) PYTHON_TRIPLE="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) PYTHON_TRIPLE="aarch64-unknown-linux-gnu" ;;
        *) echo "unsupported Linux arch: $arch" >&2; exit 1 ;;
      esac ;;
    MINGW*|MSYS*|CYGWIN*)
      PYTHON_TRIPLE="x86_64-pc-windows-msvc" ;;
    *) echo "unsupported OS: $os" >&2; exit 1 ;;
  esac
fi

# libpython 경로(존재 검사 = build.zig python_available 게이트와 동형).
case "$PYTHON_TRIPLE" in
  *darwin) LIB_REL="lib/libpython3.13.dylib" ;;
  *windows*) LIB_REL="python313.dll" ;;
  *) LIB_REL="lib/libpython3.13.so" ;;
esac

if [ -f "${DEST}/${LIB_REL}" ]; then
  echo "[stage-python] already staged: ${DEST}/${LIB_REL}"
  exit 0
fi

ASSET="cpython-${PYTHON_VERSION}+${PYTHON_PBS_TAG}-${PYTHON_TRIPLE}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_PBS_TAG}/${ASSET}"

echo "[stage-python] downloading ${ASSET}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/py.tar.gz"

mkdir -p "$DEST"
# install_only 타르볼은 top-level `python/` → strip-components=1 로 제거.
tar -xzf "$tmp/py.tar.gz" -C "$DEST" --strip-components=1

if [ ! -f "${DEST}/${LIB_REL}" ]; then
  echo "[stage-python] FAILED — ${DEST}/${LIB_REL} not found after extract" >&2
  exit 1
fi
echo "[stage-python] staged: ${DEST}/${LIB_REL}"
