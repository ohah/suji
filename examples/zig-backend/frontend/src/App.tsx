import { useState } from "react";
import { invoke, on, send, once } from "@suji/api";

const getBridge = () => (window as any).__suji__;

const S = (v: unknown) => typeof v === "object" ? JSON.stringify(v, null, 2) : String(v);

function App() {
  const [logs, setLogs] = useState<string[]>(["Ready."]);
  const [name, setName] = useState("Suji");
  const [a, setA] = useState(10);
  const [b, setB] = useState(20);

  const log = (msg: string) => setLogs((p) => [...p.slice(-30), msg]);

  const call = async (fn: () => Promise<unknown>, label: string) => {
    try {
      const r = await fn();
      log(`[${label}] ${S(r)}`);
    } catch (e) {
      log(`[${label}] ERR: ${S(e)}`);
    }
  };

  return (
    <div style={{ maxWidth: 600, margin: "0 auto", padding: 24, fontFamily: "system-ui" }}>
      <h1>Suji + Zig</h1>
      <p style={{ color: "#888", marginBottom: 24 }}>import {"{ invoke, on, send }"} from "@suji/api"</p>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#ce93d8" }}>invoke</h3>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <button onClick={() => call(() => invoke("ping"), "ping")} style={{ background: "#ce93d8", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
            invoke("ping")
          </button>
          <div>
            <input value={name} onChange={(e) => setName(e.target.value)} style={{ background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, marginRight: 4 }} />
            <button onClick={() => call(() => invoke("greet", { name }), "greet")} style={{ background: "#ce93d8", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
              invoke("greet", {`{ name }`})
            </button>
          </div>
          <div>
            <input type="number" value={a} onChange={(e) => setA(+e.target.value)} style={{ width: 50, background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, marginRight: 2 }} />
            +
            <input type="number" value={b} onChange={(e) => setB(+e.target.value)} style={{ width: 50, background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, margin: "0 4px" }} />
            <button onClick={() => call(() => invoke("add", { a, b }), "add")} style={{ background: "#ce93d8", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
              invoke("add", {`{ a, b }`})
            </button>
          </div>
        </div>
      </section>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#4fc3f7" }}>Window (PoC)</h3>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <button onClick={() => call(() => getBridge().core(JSON.stringify({ cmd: "create_window", title: "New Window", url: "https://example.com" })), "create_window")} style={{ background: "#4fc3f7", color: "#000", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
            Create Window
          </button>
        </div>
      </section>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#ce93d8" }}>on / send / once</h3>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <button onClick={() => {
            on("test", (data) => log(`  ✅ on: ${S(data)}`));
            log("📡 on('test') registered");
          }} style={{ background: "#ce93d8", border: "none", padding: "8px 12px", borderRadius: 4, cursor: "pointer", fontWeight: 600, fontSize: 12 }}>
            on("test")
          </button>
          <button onClick={() => {
            once("test-once", (data) => log(`  ✅ once: ${S(data)}`));
            log("📡 once('test-once') registered");
          }} style={{ background: "#ce93d8", border: "none", padding: "8px 12px", borderRadius: 4, cursor: "pointer", fontWeight: 600, fontSize: 12 }}>
            once("test-once")
          </button>
          <button onClick={() => {
            send("test", { msg: "hello", t: Date.now() });
            log("📤 send('test')");
          }} style={{ background: "#ce93d8", border: "none", padding: "8px 12px", borderRadius: 4, cursor: "pointer", fontWeight: 600, fontSize: 12 }}>
            send("test")
          </button>
          <button onClick={() => {
            send("test-once", { msg: "once!" });
            log("📤 send('test-once')");
          }} style={{ background: "#ce93d8", border: "none", padding: "8px 12px", borderRadius: 4, cursor: "pointer", fontWeight: 600, fontSize: 12 }}>
            send("test-once")
          </button>
        </div>
      </section>

      <div style={{ background: "#111", borderRadius: 6, padding: 14, fontFamily: "monospace", fontSize: 12, maxHeight: 250, overflowY: "auto", whiteSpace: "pre-wrap" }}>
        {logs.map((l, i) => <div key={i}>{l}</div>)}
      </div>
    </div>
  );
}

export default App;
