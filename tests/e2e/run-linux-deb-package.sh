#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "linux deb package e2e skipped on $(uname -s)"
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_BIN="$ROOT/zig-out/bin/suji"
test -x "$SUJI_BIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/frontend"
cat > "$TMP/suji.json" <<'JSON'
{
  "app": {
    "name": "deb-e2e-app",
    "version": "1.2.3"
  },
  "frontend": {
    "dir": "frontend",
    "dist_dir": "frontend/dist"
  }
}
JSON
cat > "$TMP/frontend/package.json" <<'JSON'
{
  "private": true,
  "scripts": {
    "build": "mkdir -p dist && printf '<!doctype html><title>deb e2e</title>' > dist/index.html"
  }
}
JSON
: > "$TMP/frontend/bun.lock"

(
  cd "$TMP"
  "$SUJI_BIN" build --deb
  test -f deb-e2e-app-1.2.3-linux-x64.tar.gz
  test -f deb-e2e-app_1.2.3_amd64.deb

  mkdir -p inspect/control inspect/data
  ar p deb-e2e-app_1.2.3_amd64.deb debian-binary | grep -qx '2.0'
  ar p deb-e2e-app_1.2.3_amd64.deb control.tar.gz > inspect/control.tar.gz
  ar p deb-e2e-app_1.2.3_amd64.deb data.tar.gz > inspect/data.tar.gz
  tar -xzf inspect/control.tar.gz -C inspect/control
  tar -xzf inspect/data.tar.gz -C inspect/data

  grep -qx 'Package: deb-e2e-app' inspect/control/control
  grep -qx 'Version: 1.2.3' inspect/control/control
  grep -qx 'Architecture: amd64' inspect/control/control
  test -x inspect/data/opt/deb-e2e-app/bin/deb-e2e-app
  test -f inspect/data/opt/deb-e2e-app/resources/frontend/index.html
  grep -qx 'Exec=/opt/deb-e2e-app/bin/deb-e2e-app' inspect/data/usr/share/applications/deb-e2e-app.desktop
)
