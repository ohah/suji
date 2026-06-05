"""Type stubs for Suji's embedded-Python backend `suji` module.

The `suji` module is **injected at runtime** by the Suji host
(`PyImport_AppendInittab("suji", ...)` in `src/platform/python.zig`) — it is not
a regular importable package. These stubs give IDEs / type checkers the API
surface; at runtime `import suji` resolves to the host-provided module.

See https://ohah.github.io/suji for the backend guide.
"""

from typing import Callable

# 인바운드 핸들러 등록 — handler 는 raw 요청 JSON 문자열을 받아 JSON 문자열을 반환.
# 요청은 {"cmd": <channel>, ...frontend data} 형태로 직렬화되어 온다.
def handle(channel: str, handler: Callable[[str], str]) -> None: ...

# outbound cross-call — 다른 백엔드(zig/rust/go/node/lua)를 동기 호출, 응답 JSON 반환.
def invoke(target: str, request_json: str) -> str: ...

# 이벤트 발신 — frontend / 다른 백엔드가 같은 channel 을 on 으로 수신.
def send(channel: str, data: str) -> None: ...

# 이벤트 수신 — callback 은 payload 문자열을 받는다. listener id 반환.
def on(channel: str, callback: Callable[[str], None]) -> int: ...
