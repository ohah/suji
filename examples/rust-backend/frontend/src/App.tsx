import { useState } from "react";

declare global {
  interface Window {
    __suji__: {
      invoke: (channel: string, data?: Record<string, unknown>) => Promise<unknown>;
    };
  }
}

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

  const suji = window.__suji__;

  return (
    <div style={{ maxWidth: 600, margin: "0 auto", padding: 24, fontFamily: "system-ui" }}>
      <h1>Suji + Rust</h1>
      <p style={{ color: "#888", marginBottom: 24 }}>Electron-style: suji.invoke("channel", data)</p>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#ff8a65" }}>Ping</h3>
        <button onClick={() => call(() => suji.invoke("ping"), "ping")} style={{ background: "#ff8a65", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
          suji.invoke("ping")
        </button>
      </section>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#ff8a65" }}>Greet</h3>
        <input value={name} onChange={(e) => setName(e.target.value)} style={{ background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, marginRight: 8 }} />
        <button onClick={() => call(() => suji.invoke("greet", { name }), "greet")} style={{ background: "#ff8a65", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
          suji.invoke("greet", {"{ name }"})
        </button>
      </section>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#ff8a65" }}>Add</h3>
        <input type="number" value={a} onChange={(e) => setA(+e.target.value)} style={{ width: 60, background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, marginRight: 4 }} />
        +
        <input type="number" value={b} onChange={(e) => setB(+e.target.value)} style={{ width: 60, background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, margin: "0 8px 0 4px" }} />
        <button onClick={() => call(() => suji.invoke("add", { a, b }), "add")} style={{ background: "#ff8a65", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
          suji.invoke("add", {"{ a, b }"})
        </button>
      </section>

      <div style={{ background: "#111", borderRadius: 6, padding: 14, fontFamily: "monospace", fontSize: 12, maxHeight: 200, overflowY: "auto", whiteSpace: "pre-wrap" }}>
        {logs.map((l, i) => <div key={i}>{l}</div>)}
      </div>
    </div>
  );
}

export default App;
