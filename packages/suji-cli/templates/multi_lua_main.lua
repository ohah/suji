-- multi-backend: 채널을 백엔드별 네임스페이스로 충돌 회피 (zig 가 ping/greet 소유).
-- target 없이 suji.invoke("lua-ping") 으로 자동 라우팅된다.
suji.handle("lua-ping", function()
  return '{"from":"lua","msg":"pong"}'
end)

suji.handle("lua-greet", function()
  return '{"from":"lua","greeting":"Hello from Lua!"}'
end)
