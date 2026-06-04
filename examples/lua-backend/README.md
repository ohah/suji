# Suji Lua Backend Example

This example uses the opt-in, **vendored Lua 5.4** runtime — statically linked, so
no system Lua/LuaJIT install is required and it builds identically on
macOS / Linux / Windows. `cjson` is bundled.

```sh
zig build -Dlua
cd examples/lua-backend/frontend
npm install
cd ..
../../zig-out/bin/suji dev
```

Lua handlers receive the raw Suji request JSON string and return a JSON string
response. `require("cjson")` is bundled, so handlers parse/serialize JSON without
manual escaping — see [`backends/lua/main.lua`](./backends/lua/main.lua):

```lua
local cjson = require("cjson")

suji.handle("echo", function(request_json)
  local req = cjson.decode(request_json)
  return cjson.encode({ runtime = "lua", echo = req })
end)
```
