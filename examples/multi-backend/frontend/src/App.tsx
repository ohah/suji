import { useState, useRef, useEffect } from "react";
import "./App.css";

declare global {
  interface Window {
    __suji__: {
      invoke: (backend: string, request: string) => Promise<unknown>;
      chain: (from: string, to: string, request: string) => Promise<unknown>;
      fanout: (backends: string, request: string) => Promise<unknown>;
      core: (request: string) => Promise<unknown>;
      emit: (event: string, data: unknown) => Promise<unknown>;
      on: (event: string, cb: (data: unknown) => void) => () => void;
    };
  }
}

const S = (v: unknown) =>
  typeof v === "object" ? JSON.stringify(v) : String(v);

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
      {/* 좌측: 버튼 패널 */}
      <div className="panel">
        <h1>Suji Multi-Backend</h1>
        <p className="subtitle">Zig + Rust + Go</p>

        <section>
          <h3>1. Direct Ping</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"ping"}'), "zig")}>Zig</button>
            <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"ping"}'), "rust")}>Rust</button>
            <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"ping"}'), "go")}>Go</button>
          </div>
        </section>

        <section>
          <h3>2. Greet</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"greet","name":"Suji"}'), "zig")}>Zig</button>
            <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"greet","name":"Suji"}'), "rust")}>Rust</button>
            <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"greet","name":"Suji"}'), "go")}>Go</button>
          </div>
        </section>

        <section>
          <h3>3. Cross-Backend (모든 방향)</h3>
          <p>백엔드끼리 SujiCore API로 직접 호출</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"call_rust"}'), "zig→rust")}>Zig→Rust</button>
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"call_go"}'), "zig→go")}>Zig→Go</button>
            <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"call_go"}'), "rust→go")}>Rust→Go</button>
            <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"call_rust"}'), "go→rust")}>Go→Rust</button>
          </div>
        </section>

        <section>
          <h3>3.5. Chain (Zig→Rust→Go)</h3>
          <p>Zig가 Rust와 Go를 순차/동시 호출</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"collab","data":"hello from zig"}'), "zig-collab")}>Zig leads collab</button>
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"chain_all"}'), "zig-chain")}>Zig→Rust→Go chain</button>
          </div>
        </section>

        <section>
          <h3>4. Collab (tokio + goroutine)</h3>
          <p>Rust(SHA256) + Go(통계) 협업</p>
          <div className="buttons">
            <button className="chain" onClick={() => call(() => suji.invoke("rust", '{"cmd":"collab","data":"suji is a multi-backend desktop framework built with zig"}'), "rust+go")}>Rust leads</button>
            <button className="chain" onClick={() => call(() => suji.invoke("go", '{"cmd":"collab","data":"suji is a multi-backend desktop framework built with zig"}'), "go+rust")}>Go leads</button>
          </div>
        </section>

        <section>
          <h3>5. Fan-out</h3>
          <p>모든 백엔드에 동시 요청</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.fanout("zig,rust,go", '{"cmd":"ping"}'), "fanout-all")}>Ping All</button>
            <button className="zig" onClick={() => call(() => suji.fanout("rust,go", '{"cmd":"ping"}'), "fanout-rg")}>Ping Rust+Go</button>
          </div>
        </section>

        <section>
          <h3>6. Chain (A → Zig Core → B)</h3>
          <p>한 백엔드 결과를 다른 백엔드에 전달</p>
          <div className="buttons">
            <button className="chain" onClick={() => call(() => suji.chain("rust", "go", '{"cmd":"process_and_relay","msg":"hello"}'), "rust→go")}>Rust→Zig→Go</button>
            <button className="chain" onClick={() => call(() => suji.chain("go", "rust", '{"cmd":"process_and_relay","msg":"hello"}'), "go→rust")}>Go→Zig→Rust</button>
          </div>
        </section>

        <section>
          <h3>7. Zig Core</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_info"}'), "core")}>Backend Info</button>
            <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_relay","target":"rust"}'), "zig→rust")}>Relay→Rust</button>
            <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_relay","target":"go"}'), "zig→go")}>Relay→Go</button>
          </div>
        </section>

        <section>
          <h3>8. Zig Backend</h3>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"info"}'), "zig-info")}>Info</button>
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"add","a":100,"b":200}'), "zig-add")}>Add 100+200</button>
          </div>
        </section>

        <section>
          <h3>9. Events (on/off/emit/send)</h3>
          <p>이벤트 구독 → 수신 확인 → 해제 → 수신 안 됨 확인</p>
          <div className="buttons" style={{ marginBottom: 6 }}>
            <button className="zig" onClick={() => {
              const c1 = suji.on("zig-event", (data: unknown) => log(`  ✅ [zig-event] ${S(data)}`));
              const c2 = suji.on("rust-event", (data: unknown) => log(`  ✅ [rust-event] ${S(data)}`));
              const c3 = suji.on("go-event", (data: unknown) => log(`  ✅ [go-event] ${S(data)}`));
              const c4 = suji.on("test-event", (data: unknown) => log(`  ✅ [test-event] ${S(data)}`));
              (window as any).__cancels = { zig: c1, rust: c2, go: c3, test: c4 };
              log("📡 ON: 4 listeners (zig-event, rust-event, go-event, test-event)");
            }}>1. ON (register all)</button>
            <button style={{ background: "#ef5350", fontWeight: 600, border: "none", padding: "5px 10px", borderRadius: 4, cursor: "pointer", fontSize: 11 }} onClick={() => {
              const c = (window as any).__cancels;
              if (c) {
                if (c.zig) c.zig();
                if (c.rust) c.rust();
                if (c.go) c.go();
                if (c.test) c.test();
                (window as any).__cancels = null;
                log("🔴 OFF: all listeners removed");
              } else {
                log("🔴 OFF: no listeners to remove");
              }
            }}>OFF (remove all)</button>
          </div>
          <div className="buttons" style={{ marginBottom: 6 }}>
            <button className="zig" onClick={() => call(() => suji.invoke("zig", '{"cmd":"emit_event"}'), "zig→emit")}>Zig sends event</button>
            <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"emit_event","channel":"rust-event","msg":"hi from rust"}'), "rust→emit")}>Rust sends event</button>
            <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"emit_event","msg":"hi from go"}'), "go→emit")}>Go sends event</button>
            <button className="chain" onClick={() => {
              suji.emit("test-event", { msg: "from JS", t: Date.now() });
              log("📤 JS emitted test-event");
            }}>JS emits event</button>
          </div>
          <p style={{ color: "#555", fontSize: 11 }}>테스트: ON → emit 3개 → ✅ 수신 확인 → OFF → emit 3개 → 수신 안 됨 확인</p>
        </section>

        <section>
          <h3>10. Stress Test</h3>
          <p>3개 백엔드 동시 호출</p>
          <div className="buttons">
            <button className="chain" onClick={async () => {
              log("--- Stress: 3 backends x 10 calls ---");
              const start = performance.now();
              const promises = [];
              for (let i = 0; i < 10; i++) {
                promises.push(suji.invoke("zig", `{"cmd":"ping"}`));
                promises.push(suji.invoke("rust", `{"cmd":"ping"}`));
                promises.push(suji.invoke("go", `{"cmd":"ping"}`));
              }
              await Promise.all(promises);
              const ms = (performance.now() - start).toFixed(1);
              log(`--- Stress done: 30 calls in ${ms}ms ---`);
            }}>30 calls (10 each)</button>
            <button className="chain" onClick={async () => {
              log("--- Full pipeline ---");
              const r1 = await suji.invoke("zig", '{"cmd":"greet","name":"pipeline"}');
              log(`[1/4 zig] ${S(r1)}`);
              const r2 = await suji.invoke("rust", '{"cmd":"collab","data":"pipeline test"}');
              log(`[2/4 rust+go] ${S(r2)}`);
              const r3 = await suji.fanout("zig,rust,go", '{"cmd":"ping"}');
              log(`[3/4 fanout] ${S(r3)}`);
              const r4 = await suji.chain("rust", "go", '{"cmd":"process_and_relay","msg":"done"}');
              log(`[4/4 chain] ${S(r4)}`);
              log("--- Pipeline complete ---");
            }}>Full Pipeline</button>
            <button className="chain" onClick={async () => {
              log("=== CHAOS MODE: 3 backends x cross-calls x fanout ===");
              const start = performance.now();
              const chaos = [
                // 직접 호출 동시
                suji.invoke("zig", '{"cmd":"ping"}'),
                suji.invoke("rust", '{"cmd":"ping"}'),
                suji.invoke("go", '{"cmd":"ping"}'),
                // 크로스 호출 동시
                suji.invoke("rust", '{"cmd":"call_go"}'),
                suji.invoke("go", '{"cmd":"call_rust"}'),
                // 협업 동시
                suji.invoke("rust", '{"cmd":"collab","data":"chaos test"}'),
                suji.invoke("go", '{"cmd":"collab","data":"chaos test"}'),
                // 팬아웃 동시
                suji.fanout("zig,rust,go", '{"cmd":"ping"}'),
                suji.fanout("rust,go", '{"cmd":"ping"}'),
                // 체인 동시
                suji.chain("rust", "go", '{"cmd":"process_and_relay","msg":"chaos"}'),
                suji.chain("go", "rust", '{"cmd":"process_and_relay","msg":"chaos"}'),
                // 코어 동시
                suji.core('{"cmd":"core_info"}'),
                suji.core('{"cmd":"core_relay","target":"rust"}'),
                suji.core('{"cmd":"core_relay","target":"go"}'),
                // Zig 연산 동시
                suji.invoke("zig", '{"cmd":"add","a":1,"b":2}'),
                suji.invoke("zig", '{"cmd":"greet","name":"chaos"}'),
                // 추가 크로스
                suji.invoke("rust", '{"cmd":"call_go"}'),
                suji.invoke("go", '{"cmd":"call_rust"}'),
                suji.invoke("rust", '{"cmd":"collab","data":"more chaos"}'),
                suji.invoke("go", '{"cmd":"collab","data":"more chaos"}'),
              ];
              const results = await Promise.allSettled(chaos);
              const ok = results.filter(r => r.status === "fulfilled").length;
              const fail = results.filter(r => r.status === "rejected").length;
              const ms = (performance.now() - start).toFixed(1);
              log(`=== CHAOS DONE: ${ok} ok, ${fail} fail, ${ms}ms (${results.length} total) ===`);
              results.forEach((r, i) => {
                if (r.status === "fulfilled") {
                  log(`  [${i}] ${S(r.value)}`);
                } else {
                  log(`  [${i}] FAIL: ${S(r.reason)}`);
                }
              });
            }}>CHAOS (20 concurrent)</button>
            <button className="chain" onClick={async () => {
              log("=== RAPID FIRE: 100 calls ===");
              const start = performance.now();
              const backends = ["zig", "rust", "go"];
              const promises = [];
              for (let i = 0; i < 100; i++) {
                const b = backends[i % 3];
                promises.push(suji.invoke(b, `{"cmd":"ping"}`));
              }
              const results = await Promise.allSettled(promises);
              const ok = results.filter(r => r.status === "fulfilled").length;
              const ms = (performance.now() - start).toFixed(1);
              log(`=== RAPID FIRE DONE: ${ok}/100 ok in ${ms}ms ===`);
            }}>RAPID FIRE (100)</button>
          </div>
        </section>
      </div>

      {/* 우측: 로그 패널 */}
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
