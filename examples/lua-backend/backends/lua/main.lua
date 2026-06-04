local cjson = require("cjson")

-- 핸들러는 raw 요청 JSON 문자열을 받아 JSON 문자열을 반환한다. 요청은
-- {cmd=<channel>, ...frontend data} 형태로 직렬화되어 온다. 번들된 cjson 으로
-- 파싱/직렬화하므로 수동 escape 가 필요 없다.

suji.handle("ping", function()
  return cjson.encode({ runtime = "lua", msg = "pong" })
end)

suji.handle("echo", function(request_json)
  local req = cjson.decode(request_json)
  return cjson.encode({
    runtime = "lua",
    echo = req,
    value = req.value or req.message,
  })
end)

-- 이벤트 발신(suji.send): 호출 시 "lua-event" 발행 → 프론트가 suji.on 으로 수신.
suji.handle("emit-test", function()
  suji.send("lua-event", cjson.encode({ from = "lua", msg = "tick" }))
  return cjson.encode({ sent = "lua-event" })
end)

-- 이벤트 수신(suji.on): 프론트가 emit 한 "from-frontend" 를 받아 "lua-echo" 로 되돌린다.
suji.on("from-frontend", function(data)
  suji.send("lua-echo", data)
end)
