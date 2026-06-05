# Suji Python Backend Example

This example uses the embedded **CPython 3.13** runtime (python-build-standalone,
staged at `~/.suji/python/<ver>`). No system Python required — the runtime is
bundled into the packaged app, so end users don't need Python installed.

```sh
# 개발 머신에 libpython staging (한 번만): python-build-standalone install_only 를
# ~/.suji/python/3.13.13 에 압축 해제. (CI/release 가 자동 staging.)
zig build
cd examples/python-backend/frontend
npm install
cd ..
../../zig-out/bin/suji dev
```

Python handlers receive the raw Suji request JSON string and return a JSON string
response. The standard `json` module parses/serializes — no extra dependencies.
Handlers are first-class: `suji.invoke` (cross-call), `suji.send` (emit),
`suji.on` (subscribe) — see [`backends/python/main.py`](./backends/python/main.py):

```python
import suji, json

suji.handle("ping", lambda req: json.dumps({"runtime": "python", "msg": "pong"}))
suji.handle("echo", lambda req: json.dumps({"runtime": "python", "echo": json.loads(req)}))
suji.on("from-frontend", lambda data: suji.send("python-echo", data))
```
