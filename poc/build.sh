#!/bin/bash
set -e

echo "=== Building Suji POC ==="

# 1. Rust backend
echo "[1/3] Building Rust backend (with tokio)..."
cd rust-backend
cargo build --release 2>&1
cd ..

# 2. Go backend
echo "[2/3] Building Go backend..."
cd go-backend
CGO_ENABLED=1 go build -buildmode=c-shared -o libgo_backend.dylib main.go
cd ..

# 3. Zig host
echo "[3/3] Building Zig host..."
cd zig-host
zig build-exe main.zig -OReleaseFast 2>&1 || zig build-exe main.zig 2>&1
cd ..

echo ""
echo "=== Build complete ==="
echo ""
echo "To run:"
echo "  1. Start Node backend:  node node-backend/backend.js /tmp/suji-poc-node.sock"
echo "  2. Run Zig host:        ./zig-host/main"
