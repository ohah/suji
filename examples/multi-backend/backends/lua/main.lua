local cjson = require("cjson")

-- Lua 백엔드 — 다른 백엔드(zig/rust/go/node)와 동등한 1급 시민.
-- 고유 채널 prefix `lua-*` 로 자동 라우팅 채널 충돌을 피한다.

-- 인바운드 핸들러
suji.handle("lua-ping", function()
  return cjson.encode({ from = "lua", msg = "pong" })
end)

-- outbound cross-call: Lua → Zig (suji.invoke)
suji.handle("lua-call-zig", function()
  local resp = suji.invoke("zig", cjson.encode({ cmd = "add", a = 2, b = 3 }))
  return cjson.encode({ from = "lua", zig_said = cjson.decode(resp) })
end)

-- 이벤트 발신: suji.send
suji.handle("lua-emit", function()
  suji.send("lua-event", cjson.encode({ from = "lua", msg = "hello from lua backend" }))
  return cjson.encode({ sent = "lua-event" })
end)

-- 이벤트 수신: suji.on — "ping-all" 을 받으면 받은 payload 를 "lua-heard" 로 에코.
suji.on("ping-all", function(data)
  suji.send("lua-heard", data)
end)
