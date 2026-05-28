local function escape_json_string(value)
  return value
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
end

suji.handle("ping", function()
  return '{"runtime":"lua","msg":"pong"}'
end)

suji.handle("echo", function(request_json)
  return '{"runtime":"lua","echo":"' .. escape_json_string(request_json) .. '"}'
end)
