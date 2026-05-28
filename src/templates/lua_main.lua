suji.handle("ping", function()
  return '{"msg":"pong"}'
end)

suji.handle("greet", function()
  return '{"greeting":"Hello from Lua!"}'
end)
