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

-- 네이티브 코어 cmd 호출: suji.invoke("__core__", ...) 로 Lua 백엔드도 모든 코어 API
-- (screen/window/clipboard 등)에 도달함을 실증. 여기선 screen.getDisplayMatching.
suji.handle("core-display-matching", function(request_json)
  local req = cjson.decode(request_json)
  return suji.invoke("__core__", cjson.encode({
    cmd = "screen_get_display_matching",
    x = req.x or 0,
    y = req.y or 0,
    width = req.width or 0,
    height = req.height or 0,
  }))
end)

-- 단일 인스턴스 락도 __core__ 로 도달(전 백엔드 동일 cmd). 부작용 없이 reach 만
-- 실증하려고 read-only has 사용(전역 락 상태 변경 X).
suji.handle("core-single-instance", function(_)
  return suji.invoke("__core__", cjson.encode({ cmd = "app_has_single_instance_lock" }))
end)

-- session.setProxy 도 __core__ 로 도달. 백엔드(lua 워커 스레드)에서 호출하면 UI
-- 스레드로 post 되는 경로 검증(크래시 없이 success). mode=direct(부작용 없음).
suji.handle("core-set-proxy", function(_)
  return suji.invoke("__core__", cjson.encode({ cmd = "session_set_proxy", mode = "direct" }))
end)

-- session.setPermissionRequestHandler 등록(enable)도 __core__ 로 도달.
suji.handle("core-set-permission-handler", function(_)
  return suji.invoke("__core__", cjson.encode({ cmd = "session_set_permission_handler", enabled = true }))
end)

-- 권한 응답도 __core__ 로 도달(워커 스레드). 없는 permissionId → success:false 지만
-- cmd 라우팅 + (pendingTake 실패가 호출 스레드에서 끝나 post 없이) 무크래시 검증.
suji.handle("core-permission-response", function(_)
  return suji.invoke("__core__", cjson.encode({ cmd = "session_permission_response", permissionId = 999999, granted = true }))
end)
