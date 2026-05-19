import { useState } from "react";
import { invoke } from "./suji";

export default function App() {
  const [name, setName] = useState("Suji");
  const [log, setLog] = useState("Ready. 백엔드 핸들러를 호출해 보세요.");

  const call = (label: string, run: () => Promise<unknown>) => async () => {
    try {
      setLog(`[${label}] ${JSON.stringify(await run())}`);
    } catch (e) {
      setLog(`[${label}] ERR: ${String(e)}`);
    }
  };

  return (
    <main
      style={{
        maxWidth: 560,
        margin: "0 auto",
        padding: 32,
        fontFamily: "system-ui, sans-serif",
      }}
    >
      <h1>Suji + React</h1>
      <p style={{ color: "#888" }}>
        <code>import {"{ invoke }"} from "./suji"</code>
      </p>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 24 }}>
        <button onClick={call("ping", () => invoke("ping"))}>
          invoke("ping")
        </button>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-label="name"
        />
        <button onClick={call("greet", () => invoke("greet", { name }))}>
          invoke("greet", {"{ name }"})
        </button>
      </div>

      <pre
        style={{
          marginTop: 24,
          padding: 14,
          background: "#111",
          color: "#0f0",
          borderRadius: 6,
          whiteSpace: "pre-wrap",
        }}
      >
        {log}
      </pre>
    </main>
  );
}
