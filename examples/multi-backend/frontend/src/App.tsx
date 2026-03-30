import { useState } from "react";
import "./App.css";

declare global {
  interface Window {
    __suji__: {
      invoke: (backend: string, request: string) => Promise<unknown>;
      chain: (from: string, to: string, request: string) => Promise<unknown>;
      fanout: (backends: string, request: string) => Promise<unknown>;
      core: (request: string) => Promise<unknown>;
    };
  }
}

const S = (v: unknown) =>
  typeof v === "object" ? JSON.stringify(v, null, 2) : String(v);

function App() {
  const [logs, setLogs] = useState<string[]>(["Ready."]);

  const log = (msg: string) => setLogs((prev) => [...prev.slice(-50), msg]);

  const call = async (fn: () => Promise<unknown>, label: string) => {
    try {
      const result = await fn();
      log(`[${label}] ${S(result)}`);
    } catch (e) {
      log(`[${label}] ERR: ${S(e)}`);
    }
  };

  const suji = window.__suji__;

  return (
    <div className="app">
      <h1>Suji</h1>
      <p className="subtitle">Zig core multi-backend desktop framework</p>

      <section>
        <h3>1. Direct Call</h3>
        <p>JS에서 각 백엔드를 직접 호출</p>
        <div className="buttons">
          <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"ping"}'), "rust")}>Rust ping</button>
          <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"ping"}'), "go")}>Go ping</button>
        </div>
      </section>

      <section>
        <h3>2. Cross-Backend Call</h3>
        <p>백엔드가 Zig 코어를 통해 다른 백엔드를 직접 호출</p>
        <div className="buttons">
          <button className="rust" onClick={() => call(() => suji.invoke("rust", '{"cmd":"call_go"}'), "rust→go")}>Rust calls Go</button>
          <button className="go" onClick={() => call(() => suji.invoke("go", '{"cmd":"call_rust"}'), "go→rust")}>Go calls Rust</button>
        </div>
      </section>

      <section>
        <h3>3. Collaboration (tokio + goroutine)</h3>
        <p>Rust(SHA256 해싱) + Go(텍스트 통계)가 협업</p>
        <div className="buttons">
          <button className="chain" onClick={() => call(() => suji.invoke("rust", '{"cmd":"collab","data":"suji framework is awesome"}'), "rust+go")}>Rust leads collab</button>
          <button className="chain" onClick={() => call(() => suji.invoke("go", '{"cmd":"collab","data":"suji framework is awesome"}'), "go+rust")}>Go leads collab</button>
        </div>
      </section>

      <section>
        <h3>4. Fan-out & Zig Core</h3>
        <p>Zig 코어가 여러 백엔드에 동시 요청 또는 직접 처리</p>
        <div className="buttons">
          <button className="zig" onClick={() => call(() => suji.fanout("rust,go", '{"cmd":"ping"}'), "fanout")}>Ping All</button>
          <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_info"}'), "zig-core")}>Backend Info</button>
          <button className="zig" onClick={() => call(() => suji.core('{"cmd":"core_relay","target":"rust"}'), "zig→rust")}>Zig → Rust</button>
        </div>
      </section>

      <div className="output">
        {logs.map((line, i) => (
          <div key={i}>{line}</div>
        ))}
      </div>
    </div>
  );
}

export default App;
