import { createSignal } from "solid-js";
import { invoke } from "./suji";

export default function App() {
  const [name, setName] = createSignal("Suji");
  const [log, setLog] = createSignal("Ready. 백엔드 핸들러를 호출해 보세요.");

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
        "max-width": "560px",
        margin: "0 auto",
        padding: "32px",
        "font-family": "system-ui, sans-serif",
      }}
    >
      <h1>Suji + Solid</h1>
      <p style={{ color: "#888" }}>
        <code>import {"{ invoke }"} from "./suji"</code>
      </p>

      <div
        style={{
          display: "flex",
          gap: "8px",
          "flex-wrap": "wrap",
          "margin-top": "24px",
        }}
      >
        <button onClick={call("ping", () => invoke("ping"))}>
          invoke("ping")
        </button>
        <input
          value={name()}
          onInput={(e) => setName(e.currentTarget.value)}
          aria-label="name"
        />
        <button onClick={call("greet", () => invoke("greet", { name: name() }))}>
          invoke("greet", {"{ name }"})
        </button>
      </div>

      <pre
        style={{
          "margin-top": "24px",
          padding: "14px",
          background: "#111",
          color: "#0f0",
          "border-radius": "6px",
          "white-space": "pre-wrap",
        }}
      >
        {log()}
      </pre>
    </main>
  );
}
