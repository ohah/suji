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
HTTPS_PID=""
cleanup() {
  if [ -n "$HTTPS_PID" ]; then
    kill "$HTTPS_PID" 2>/dev/null || true
    wait "$HTTPS_PID" 2>/dev/null || true
  fi
  rm -rf "$OUT"
}
trap cleanup EXIT

start_https_fixture() {
  if ! command -v python3 >/dev/null || ! command -v openssl >/dev/null; then
    echo "[https] python3/openssl 미발견 — HTTPS subtest skip"
    return 0
  fi

  cat > "$OUT/localhost-openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = localhost
[v3_req]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -sha256 \
    -keyout "$OUT/localhost.key" -out "$OUT/localhost.crt" \
    -config "$OUT/localhost-openssl.cnf" >/dev/null 2>&1 || {
      echo "[https] openssl self-signed cert 생성 실패 — HTTPS subtest skip"
      return 0
    }

  cat > "$OUT/https_server.py" <<'PY'
import http.server
import ssl
import sys

cert, key, port_file = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"SUJI_HTTPS_OK"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=cert, keyfile=key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

  local port_file="$OUT/https-port"
  python3 "$OUT/https_server.py" \
    "$OUT/localhost.crt" "$OUT/localhost.key" "$port_file" \
    >"$OUT/https.log" 2>&1 &
  HTTPS_PID="$!"

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$port_file" ] && break
    sleep 0.2
  done
  if [ ! -s "$port_file" ]; then
    echo "[https] HTTPS fixture 기동 실패 — HTTPS subtest skip"
    if [ -s "$OUT/https.log" ]; then cat "$OUT/https.log"; fi
    kill "$HTTPS_PID" 2>/dev/null || true
    HTTPS_PID=""
    return 0
  fi

  export SUJI_TEST_HTTPS_URL="https://localhost:$(cat "$port_file")/"
  export SUJI_TEST_CA_BUNDLE="$OUT/localhost.crt"
}

start_https_fixture

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

echo "[5/7] sqlite backend (build-lib + vendored sqlite3.c, host)"
bash "$REPO/examples/ios/backends/sqlite/build-lib.sh" host "$OUT" >/dev/null

# Python(embedded CPython) — 데스크탑 libpython 이 staged 면 모바일 backend_android.c
# 를 호스트 타깃으로 컴파일·링크해 CI 에서 ping/echo 왕복까지 자동 검증한다.
# 미staging(로컬 fast path)은 graceful skip → 기존 5-백엔드 하니스 그대로 동작.
echo "[6/7] python backend (embedded CPython, host — backend_android.c)"
PY_HOME="$HOME/.suji/python/3.13.13"
PY_INC="$PY_HOME/include/python3.13"
case "$(uname -s)" in Darwin) PY_LIBF="$PY_HOME/lib/libpython3.13.dylib" ;; *) PY_LIBF="$PY_HOME/lib/libpython3.13.so" ;; esac
PY_FLAGS=()
if [ -f "$PY_LIBF" ] && [ -d "$PY_INC" ]; then
  # backend_android.c 는 순수 C — real clang 이 bionic/pyatomic 무사(zig translate-c 한정 함정).
  cc -c "$REPO/examples/ios/backends/python/src/backend_android.c" \
     -I"$PY_INC" -I"$REPO/include" -fPIC -O2 -o "$OUT/backend_python.o"
  ar rcs "$OUT/libsuji_python_backend.a" "$OUT/backend_python.o"
  PY_FLAGS=(-DSUJI_HAVE_PYTHON "$OUT/libsuji_python_backend.a"
            -L"$PY_HOME/lib" -lpython3.13 -Wl,-rpath,"$PY_HOME/lib")
  export SUJI_PY_HOME="$PY_HOME" SUJI_PY_MAIN="$REPO/examples/ios/backends/python/main.py"
  echo "  python staged → ping/echo 왕복 검증 활성"
else
  echo "  [SKIP] desktop libpython 미staging — python 케이스 제외 (bash scripts/stage-python.sh)"
fi

echo "[7/7] link + run"
EXTRA=()
case "$(uname -s)" in
  Darwin) EXTRA=(-lresolv -framework CoreFoundation -framework Security) ;;
  Linux)  EXTRA=(-lresolv -lpthread -lm) ;;
  *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac
cc "$HERE/verify.c" \
   "$OUT/libsuji_core.a" "$OUT/libsuji_rs_backend.a" "$OUT/libsuji_go_backend.a" \
   "$OUT/libsuji_zig_backend.a" "$OUT/libsuji_sqlite_backend.a" \
   ${PY_FLAGS[@]+"${PY_FLAGS[@]}"} \
   -I"$REPO/include" "${EXTRA[@]}" -o "$OUT/verify"
"$OUT/verify"
