# Suji Lua Backend Example

This example uses the opt-in LuaJIT runtime.

```sh
zig build -Dlua
cd examples/lua-backend/frontend
npm install
cd ..
../../zig-out/bin/suji dev
```

Lua handlers currently receive the raw Suji request JSON string and return a JSON
string response. Bundled `cjson`/LuaRocks support is planned after this first
runtime slice.
