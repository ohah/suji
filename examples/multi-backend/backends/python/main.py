import suji
import json

# Python 백엔드 — 다른 백엔드(zig/rust/go/node/lua)와 동등한 1급 시민.
# 고유 채널 prefix `python-*` 로 자동 라우팅 채널 충돌을 피한다.


# 인바운드 핸들러
def python_ping(request_json):
    return json.dumps({"from": "python", "msg": "pong"})


suji.handle("python-ping", python_ping)


# outbound cross-call: Python → Zig (suji.invoke)
def python_call_zig(request_json):
    resp = suji.invoke("zig", json.dumps({"cmd": "add", "a": 2, "b": 3}))
    return json.dumps({"from": "python", "zig_said": json.loads(resp)})


suji.handle("python-call-zig", python_call_zig)


# 이벤트 발신: suji.send
def python_emit(request_json):
    suji.send("python-event", json.dumps({"from": "python", "msg": "hello from python backend"}))
    return json.dumps({"sent": "python-event"})


suji.handle("python-emit", python_emit)


# 이벤트 수신: suji.on — "ping-all" 을 받으면 받은 payload 를 "python-heard" 로 에코.
suji.on("ping-all", lambda data: suji.send("python-heard", data))
