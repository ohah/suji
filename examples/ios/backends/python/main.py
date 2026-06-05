import suji
import json

# iOS/Android embedded CPython 백엔드 — 데스크탑 examples/python-backend 와 동형.
# 핸들러는 raw 요청 JSON({"cmd":<channel>,...})을 받아 JSON 문자열을 반환한다.
# suji.handle 로 등록한 이름이 그대로 프론트 invoke 채널이 된다(호스트가
# suji_python_backend_channels 로 목록을 받아 suji_core_register_handler 로 등록).


def ping(request_json):
    return json.dumps({"runtime": "python", "msg": "pong"})


def echo(request_json):
    req = json.loads(request_json)
    return json.dumps({
        "runtime": "python",
        "echo": req,
        "value": req.get("value") or req.get("message"),
    })


suji.handle("ping", ping)
suji.handle("echo", echo)
