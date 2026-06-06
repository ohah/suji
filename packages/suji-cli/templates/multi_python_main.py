import suji
import json

# multi-backend: 채널을 백엔드별 네임스페이스로 충돌 회피 (zig 가 ping/greet 소유).
# target 없이 suji.invoke("python-ping") 으로 자동 라우팅된다.


def ping(request_json):
    return json.dumps({"from": "python", "msg": "pong"})


def greet(request_json):
    return json.dumps({"from": "python", "greeting": "Hello from Python!"})


suji.handle("python-ping", ping)
suji.handle("python-greet", greet)
