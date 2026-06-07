import suji
import json

# 핸들러는 raw 요청 JSON 문자열을 받아 JSON 문자열을 반환한다. 요청은
# {"cmd": <channel>, ...frontend data} 형태로 직렬화되어 온다. Python 은 표준
# json 모듈로 파싱/직렬화하므로 별도 의존성이 없다.


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


# 이벤트 발신(suji.send): 호출 시 "python-event" 발행 → 프론트가 suji.on 으로 수신.
def emit_test(request_json):
    suji.send("python-event", json.dumps({"from": "python", "msg": "tick"}))
    return json.dumps({"sent": "python-event"})


suji.handle("emit-test", emit_test)


# 이벤트 수신(suji.on): 프론트가 emit 한 "from-frontend" 를 받아 "python-echo" 로 되돌린다.
suji.on("from-frontend", lambda data: suji.send("python-echo", data))


# 네이티브 코어 cmd 호출: suji.invoke("__core__", ...) 로 Python 백엔드도 모든 코어
# API(screen/window/clipboard 등)에 도달함을 실증. 여기선 screen.getDisplayMatching.
def core_display_matching(request_json):
    req = json.loads(request_json)
    return suji.invoke("__core__", json.dumps({
        "cmd": "screen_get_display_matching",
        "x": req.get("x", 0),
        "y": req.get("y", 0),
        "width": req.get("width", 0),
        "height": req.get("height", 0),
    }))


suji.handle("core-display-matching", core_display_matching)


# 단일 인스턴스 락도 __core__ 로 도달(전 백엔드 동일 cmd). 부작용 없이 reach 만
# 실증하려고 read-only has 사용(전역 락 상태 변경 X).
def core_single_instance(_request_json):
    return suji.invoke("__core__", json.dumps({"cmd": "app_has_single_instance_lock"}))


suji.handle("core-single-instance", core_single_instance)


# session.setProxy 도 __core__ 로 도달. 백엔드(python 워커 스레드)에서 호출하면 UI
# 스레드로 post 되는 경로 검증(크래시 없이 success). mode=direct(부작용 없음).
def core_set_proxy(_request_json):
    return suji.invoke("__core__", json.dumps({"cmd": "session_set_proxy", "mode": "direct"}))


suji.handle("core-set-proxy", core_set_proxy)
