import { useState } from "react";

declare global {
  interface Window {
    __suji__: {
      invoke: (backend: string, request: string) => Promise<unknown>;
    };
  }
}

const S = (v: unknown) => typeof v === "object" ? JSON.stringify(v, null, 2) : String(v);

function App() {
  const [logs, setLogs] = useState<string[]>(["Ready."]);
  const [text, setText] = useState("hello suji framework");

  const log = (msg: string) => setLogs((p) => [...p.slice(-30), msg]);

  const call = async (req: string, label: string) => {
    try {
      const r = await window.__suji__.invoke("go", req);
      log(`[${label}] ${S(r)}`);
    } catch (e) {
      log(`[${label}] ERR: ${S(e)}`);
    }
  };

  return (
    <div style={{ maxWidth: 600, margin: "0 auto", padding: 24, fontFamily: "system-ui" }}>
      <h1>Suji + Go</h1>
      <p style={{ color: "#888", marginBottom: 24 }}>Single Go backend example</p>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#81c784" }}>Ping</h3>
        <button onClick={() => call('{"cmd":"ping"}', "ping")} style={{ background: "#81c784", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
          Ping Go
        </button>
      </section>

      <section style={{ background: "#1a1a1a", borderRadius: 8, padding: 16, marginBottom: 12 }}>
        <h3 style={{ color: "#81c784" }}>Text Processing</h3>
        <input value={text} onChange={(e) => setText(e.target.value)} style={{ width: "100%", background: "#222", color: "#fff", border: "1px solid #444", padding: 8, borderRadius: 4, marginBottom: 8 }} />
        <div style={{ display: "flex", gap: 6 }}>
          <button onClick={() => call(JSON.stringify({ cmd: "upper", text }), "upper")} style={{ background: "#81c784", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
            Uppercase
          </button>
          <button onClick={() => call(JSON.stringify({ cmd: "words", text }), "words")} style={{ background: "#81c784", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
            Word Count
          </button>
          <button onClick={() => call(JSON.stringify({ cmd: "greet", name: text }), "greet")} style={{ background: "#81c784", border: "none", padding: "8px 16px", borderRadius: 4, cursor: "pointer", fontWeight: 600 }}>
            Greet
          </button>
        </div>
      </section>

      <div style={{ background: "#111", borderRadius: 6, padding: 14, fontFamily: "monospace", fontSize: 12, maxHeight: 200, overflowY: "auto", whiteSpace: "pre-wrap" }}>
        {logs.map((l, i) => <div key={i}>{l}</div>)}
      </div>
    </div>
  );
}

export default App;
