#!/usr/bin/env bash
# 모바일 정적 백엔드 메커니즘 호스트 검증.
#
# 코어(zig) + Rust(cargo staticlib) + Go(c-archive) 를 호스트 타깃으로 빌드해
# 한 바이너리에 정적 링크하고, iOS Backends.swift 와 동일 경로
# (suji_core_register_handler → 백엔드 handle_ipc)를 실제 실행 검증한다.
# iOS 실기기 없이 메커니즘 전체를 잡는다 (CEF/WKWebView 무관).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/.build"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

echo "[1/5] core (zig build lib, host)"
( cd "$REPO" && zig build lib >/dev/null )
cp "$REPO/zig-out/lib/libsuji_core.a" "$OUT/libsuji_core.a"

echo "[2/5] rust backend (cargo staticlib, host)"
cargo build --release --quiet \
  --manifest-path "$REPO/examples/ios/backends/rust/Cargo.toml"
cp "$REPO/examples/ios/backends/rust/target/release/libsuji_rs_backend.a" \
   "$OUT/libsuji_rs_backend.a"

echo "[3/5] go backend (c-archive, host)"
( cd "$REPO/examples/ios/backends/go" && \
  CGO_ENABLED=1 go build -buildmode=c-archive -o "$OUT/libsuji_go_backend.a" . )

echo "[4/6] zig backend (build-lib, host)"
zig build-lib -O ReleaseSmall -fPIC -lc \
  -femit-bin="$OUT/libsuji_zig_backend.a" \
  --name suji_zig_backend "$REPO/examples/ios/backends/zig/src/backend.zig"
rm -f "$OUT/libsuji_zig_backend.a.o"

echo "[5/6] sqlite backend (build-lib + vendored sqlite3.c, host)"
bash "$REPO/examples/ios/backends/sqlite/build-lib.sh" host "$OUT" >/dev/null

echo "[6/6] link + run"
EXTRA=()
case "$(uname -s)" in
  Darwin) EXTRA=(-lresolv -framework CoreFoundation -framework Security) ;;
  Linux)  EXTRA=(-lresolv -lpthread -lm) ;;
  *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac
cc "$HERE/verify.c" \
   "$OUT/libsuji_core.a" "$OUT/libsuji_rs_backend.a" "$OUT/libsuji_go_backend.a" \
   "$OUT/libsuji_zig_backend.a" "$OUT/libsuji_sqlite_backend.a" \
   -I"$REPO/include" "${EXTRA[@]}" -o "$OUT/verify"
"$OUT/verify"
