import { useState, useRef, useEffect } from "react";
import "./App.css";

declare global {
  interface Window {
    __suji__: {
      invoke: (channel: string, data?: Record<string, unknown>, options?: { target?: string }) => Promise<unknown>;
      chain: (from: string, to: string, request: string) => Promise<unknown>;
      fanout: (backends: string, request: string) => Promise<unknown>;
      core: (request: string) => Promise<unknown>;
      emit: (event: string, data: unknown) => Promise<unknown>;
      on: (event: string, cb: (data: unknown) => void) => () => void;
    };
  }
}

const S = (v: unknown) => typeof v === "object" ? JSON.stringify(v) : String(v);

function App() {
  const [logs, setLogs] = useState<string[]>(["Ready."]);
  const logRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [logs]);

  const log = (msg: string) => setLogs((p) => [...p.slice(-100), msg]);
  const clear = () => setLogs(["Cleared."]);

  const call = async (fn: () => Promise<unknown>, label: string) => {
    const start = performance.now();
    try {
      const result = await fn();
      const ms = (performance.now() - start).toFixed(1);
      log(`[${label}] (${ms}ms) ${S(result)}`);
    } catch (e) {
      log(`[${label}] ERR: ${S(e)}`);
    }
  };

  const suji = window.__suji__;

  return (
    <div className="layout">
      <div className="panel">
        <h1>Suji Multi-Backend</h1>
        <p className="subtitle">Zig + Rust + Go + Node.js — Electron-style API</p>

        <section>
          <h3>0. 멀티 윈도우 (DevTools 검증용)</h3>
          <p>각 창에서 <kbd>F12</kbd> 또는 <kbd>Cmd+Shift+I</kbd> 눌러 독립적으로 DevTools가 뜨는지 확인.</p>
          <div className="buttons">
            <button
              className="zig"
              onClick={() => call(
                () => suji.core(JSON.stringify({
                  cmd: "create_window",
                  title: "Window 2",
                  url: "http://localhost:5173",
                  name: "second",
                })),
                "create-window-2",
              )}
            >
              두 번째 창 띄우기
            </button>
            <button
              className="zig"
              onClick={() => call(
                () => suji.core(JSON.stringify({
                  cmd: "create_window",
                  title: "Window 3",
                  url: "http://localhost:5173",
                  name: "third",
                })),
                "create-window-3",
              )}
            >
              세 번째 창 띄우기
            </button>
            <button
              className="zig"
              onClick={() => call(
                () => suji.invoke("zig-whoami", {}, { target: "zig" }),
                "whoami",
              )}
            >
              whoami (현재 창 정보)
            </button>
          </div>
        </section>

        <section>
          <h3>1. Auto-routing vs Target</h3>
          <p>고유 채널은 자동, 중복 채널은 에러 → target 필수</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("add", { a: 10, b: 20 }), "auto")}>invoke("add") — 자동 (Zig만 등록)</button>
            <button className="zig" onClick={() => call(() => suji.invoke("info"), "auto")}>invoke("info") — 자동 (Zig만 등록)</button>
            <button style={{ background: "#ef5350", color: "#fff", fontWeight: 600, border: "none", padding: "5px 10px", borderRadius: 4, cursor: "pointer", fontSize: 11 }} onClick={() => call(() => suji.invoke("ping"), "duplicate")}>invoke("ping") — 에러 (3개 중복)</button>
            <button className="zig" onClick={() => call(() => suji.invoke("ping", {}, { target: "zig" }), "target")}>invoke("ping", {"{}"}, {"{target:'zig'}"}) — OK</button>
          </div>
        </section>

        <section>
          <h3>2. Direct Ping (target 지정)</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("ping", {}, { target: "zig" }), "zig")}>Zig</button>
            <button className="rust" onClick={() => call(() => suji.invoke("ping", {}, { target: "rust" }), "rust")}>Rust</button>
            <button className="go" onClick={() => call(() => suji.invoke("ping", {}, { target: "go" }), "go")}>Go</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-ping", {}, { target: "node" }), "node")}>Node.js</button>
          </div>
        </section>

        <section>
          <h3>2. Greet (target 지정)</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("greet", { name: "Suji" }, { target: "zig" }), "zig")}>Zig</button>
            <button className="rust" onClick={() => call(() => suji.invoke("greet", { name: "Suji" }, { target: "rust" }), "rust")}>Rust</button>
            <button className="go" onClick={() => call(() => suji.invoke("greet", { name: "Suji" }, { target: "go" }), "go")}>Go</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-greet", { name: "Suji" }, { target: "node" }), "node")}>Node.js</button>
          </div>
        </section>

        <section>
          <h3>2.5 Node.js</h3>
          <p>런타임 정보 + 시스템 정보 + crypto</p>
          <div className="buttons">
            <button className="node" onClick={() => call(() => suji.invoke("node-info"), "node-info")}>Runtime Info</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-system"), "node-system")}>System Info</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-hash", { text: "hello suji" }), "node-hash")}>Hash("hello suji")</button>
          </div>
        </section>

        <section>
          <h3>3. Cross-Backend</h3>
          <p>백엔드끼리 직접 호출</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("call_rust", {}, { target: "zig" }), "zig→rust")}>Zig→Rust</button>
            <button className="zig" onClick={() => call(() => suji.invoke("call_go", {}, { target: "zig" }), "zig→go")}>Zig→Go</button>
            <button className="rust" onClick={() => call(() => suji.invoke("call_go", {}, { target: "rust" }), "rust→go")}>Rust→Go</button>
            <button className="go" onClick={() => call(() => suji.invoke("call_rust", {}, { target: "go" }), "go→rust")}>Go→Rust</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-call-zig"), "node→zig")}>Node→Zig</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-call-rust"), "node→rust")}>Node→Rust</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-call-go"), "node→go")}>Node→Go</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-call-all"), "node→all")}>Node→All</button>
          </div>
        </section>

        <section>
          <h3>4. Collab (tokio + goroutine + Node.js)</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("collab", { data: "zig leads" }, { target: "zig" }), "zig-collab")}>Zig leads</button>
            <button className="rust" onClick={() => call(() => suji.invoke("collab", { data: "rust leads" }, { target: "rust" }), "rust-collab")}>Rust leads</button>
            <button className="go" onClick={() => call(() => suji.invoke("collab", { data: "go leads" }, { target: "go" }), "go-collab")}>Go leads</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-collab", { data: "node leads" }), "node-collab")}>Node leads</button>
            <button className="zig" onClick={() => call(() => suji.invoke("chain_all", {}, { target: "zig" }), "chain")}>Zig→Rust→Go</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-chain-all"), "node-chain")}>Node→Zig→Rust→Go</button>
          </div>
        </section>

        <section>
          <h3>5. Fan-out & Core</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.fanout("zig,rust,go", '{"cmd":"ping"}'), "fanout")}>Ping All</button>
            <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_info"}'), "core")}>Backend Info</button>
          </div>
        </section>

        <section>
          <h3>6. Events (on/off/emit)</h3>
          <div className="buttons" style={{ marginBottom: 6 }}>
            <button className="zig" onClick={() => {
              const c1 = suji.on("zig-event", (data: unknown) => log(`  ✅ [zig-event] ${S(data)}`));
              const c2 = suji.on("rust-event", (data: unknown) => log(`  ✅ [rust-event] ${S(data)}`));
              const c3 = suji.on("go-event", (data: unknown) => log(`  ✅ [go-event] ${S(data)}`));
              const c4 = suji.on("node-event", (data: unknown) => log(`  ✅ [node-event] ${S(data)}`));
              (window as any).__cancels = { zig: c1, rust: c2, go: c3, node: c4 };
              log("📡 ON: 4 listeners registered");
            }}>ON</button>
            <button style={{ background: "#ef5350", fontWeight: 600, border: "none", padding: "5px 10px", borderRadius: 4, cursor: "pointer", fontSize: 11 }} onClick={() => {
              const c = (window as any).__cancels;
              if (c) { c.zig?.(); c.rust?.(); c.go?.(); c.node?.(); (window as any).__cancels = null; log("🔴 OFF"); }
              else log("🔴 no listeners");
            }}>OFF</button>
          </div>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("emit_event", {}, { target: "zig" }), "zig→emit")}>Zig sends</button>
            <button className="rust" onClick={() => call(() => suji.invoke("emit_event", { channel: "rust-event", msg: "hi" }, { target: "rust" }), "rust→emit")}>Rust sends</button>
            <button className="go" onClick={() => call(() => suji.invoke("emit_event", { msg: "hi" }, { target: "go" }), "go→emit")}>Go sends</button>
            <button className="node" onClick={() => call(() => suji.invoke("node-emit-event"), "node→emit")}>Node sends</button>
          </div>
        </section>

        <section>
          <h3>7. State Plugin</h3>
          <p>KV Store — 모든 백엔드 + Renderer 공유</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("state:set", { key: "user", value: "yoon" }), "state:set")}>set("user", "yoon")</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:get", { key: "user" }), "state:get")}>get("user")</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:set", { key: "count", value: 42 }), "state:set")}>set("count", 42)</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:get", { key: "count" }), "state:get")}>get("count")</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:keys"), "state:keys")}>keys()</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:delete", { key: "user" }), "state:delete")}>delete("user")</button>
            <button className="zig" onClick={() => call(() => suji.invoke("state:clear"), "state:clear")}>clear()</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => {
              const cancel = suji.on("state:user", (data: unknown) => log(`  [state:user] ${S(data)}`));
              (window as any).__stateCancel = cancel;
              log("state:user watch ON");
            }}>watch("user")</button>
            <button style={{ background: "#ef5350", color: "#fff", fontWeight: 600, border: "none", padding: "5px 10px", borderRadius: 4, cursor: "pointer", fontSize: 11 }} onClick={() => {
              const c = (window as any).__stateCancel;
              if (c) { c(); (window as any).__stateCancel = null; log("state:user watch OFF"); }
            }}>unwatch</button>
          </div>
        </section>

        <section>
          <h3>8. Stress</h3>
          <div className="buttons">
            <button className="chain" onClick={async () => {
              log("--- 30 calls ---");
              const start = performance.now();
              const p = [];
              for (let i = 0; i < 10; i++) {
                p.push(suji.invoke("ping", {}, { target: "zig" }));
                p.push(suji.invoke("ping", {}, { target: "rust" }));
                p.push(suji.invoke("ping", {}, { target: "go" }));
              }
              await Promise.all(p);
              log(`--- done: ${(performance.now() - start).toFixed(1)}ms ---`);
            }}>30 calls</button>
            <button className="chain" onClick={async () => {
              log("=== CHAOS ===");
              const start = performance.now();
              const r = await Promise.allSettled([
                suji.invoke("ping", {}, { target: "zig" }),
                suji.invoke("ping", {}, { target: "rust" }),
                suji.invoke("ping", {}, { target: "go" }),
                suji.invoke("call_rust", {}, { target: "zig" }),
                suji.invoke("call_go", {}, { target: "zig" }),
                suji.invoke("collab", { data: "chaos" }, { target: "rust" }),
                suji.invoke("collab", { data: "chaos" }, { target: "go" }),
                suji.fanout("zig,rust,go", '{"cmd":"ping"}'),
                suji.invoke("add", { a: 1, b: 2 }, { target: "zig" }),
              ]);
              const ok = r.filter(x => x.status === "fulfilled").length;
              log(`=== ${ok}/${r.length} ok in ${(performance.now() - start).toFixed(1)}ms ===`);
            }}>CHAOS</button>
          </div>
        </section>
      </div>

      <div className="log-panel">
        <div className="log-header">
          <span>Output</span>
          <button onClick={clear} style={{ background: "#333", color: "#888", border: "none", padding: "4px 8px", borderRadius: 3, cursor: "pointer", fontSize: 11 }}>Clear</button>
        </div>
        <div className="output" ref={logRef}>
          {logs.map((l, i) => <div key={i}>{l}</div>)}
        </div>
      </div>
    </div>
  );
}

export default App;
