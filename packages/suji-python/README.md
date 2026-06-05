# suji-stubs

[PEP 561](https://peps.python.org/pep-0561/) **type stubs** for the `suji` module
used inside a [Suji](https://github.com/ohah/suji) embedded-Python backend.

The `suji` module is **provided by the Suji host at runtime** (embedded CPython,
injected via `PyImport_AppendInittab`) — it is *not* a normal pip package. There
is no runtime code here: this distribution only ships `.pyi` stubs so that
editors and type checkers (mypy/pyright) understand `suji.handle` /
`suji.invoke` / `suji.send` / `suji.on` in your backend source.

```sh
pip install suji-stubs   # dev-only; type info for your IDE
```

```python
import suji
import json

def ping(request_json: str) -> str:        # type-checked against the stub
    return json.dumps({"msg": "pong"})

suji.handle("ping", ping)
```

> Installing this package does **not** make `import suji` work in a plain Python
> process — it only resolves when your code runs inside a Suji app (`suji dev` /
> packaged app). Run the backend with Suji, not bare `python`.

## API

| function | signature | purpose |
|----------|-----------|---------|
| `handle` | `(channel: str, handler: Callable[[str], str]) -> None` | 인바운드 핸들러 등록 |
| `invoke` | `(target: str, request_json: str) -> str` | outbound cross-call (동기) |
| `send` | `(channel: str, data: str) -> None` | 이벤트 발신 |
| `on` | `(channel: str, callback: Callable[[str], None]) -> int` | 이벤트 수신 |

Publishing is handled by the SDK release workflow (PyPI token pending).
