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
  // Red/Blue 슬롯 각 1개씩 — 한 버튼 = 한 view 토글. 누적 생성 방지.
  const [redId, setRedId] = useState<number | null>(null);
  const [blueId, setBlueId] = useState<number | null>(null);
  const logRef = useRef<HTMLDivElement>(null);
  // suji dev 시작 시 첫 창은 항상 windowId=1 — view 데모는 그 창을 host로 사용.
  const HOST_ID = 1;

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [logs]);

  const log = (msg: string) => setLogs((p) => [...p.slice(-100), msg]);
  const clear = () => setLogs(["Cleared."]);
  const suji = window.__suji__;
  const core = (request: Record<string, unknown>) => suji.core(JSON.stringify(request));

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

  return (
    <div className="layout">
      <div className="panel">
        <div className="drag-demo">
          Drag region demo — frameless 창에서는 이 영역을 잡고 이동할 수 있습니다.
          <button
            onClick={() => call(
              () => core({
                cmd: "create_window",
                title: "Frameless Drag Demo",
                url: "http://localhost:5173",
                name: "frameless-drag",
                frame: false,
                width: 920,
                height: 680,
              }),
              "frameless-drag-window",
            )}
          >
            Frameless 창 열기
          </button>
        </div>

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
          <h3>8. Native Desktop APIs</h3>
          <p>Clipboard / Shell / Dialog / Tray / Notification / Menu / File System 수동 확인.</p>
          <div className="buttons">
            <button className="zig" onClick={() => call(() => core({ cmd: "clipboard_write_text", text: "hello from Suji demo" }), "clipboard-write")}>Clipboard write</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "clipboard_read_text" }), "clipboard-read")}>Clipboard read</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "clipboard_clear" }), "clipboard-clear")}>Clipboard clear</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "shell_beep" }), "shell-beep")}>Beep</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "shell_open_external", url: "https://example.com" }), "shell-open")}>Open URL</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "shell_show_item_in_folder", path: "/tmp" }), "shell-show-item")}>Show /tmp</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => call(() => core({ cmd: "dialog_show_message_box", type: "info", title: "Suji", message: "Message box from demo", buttons: ["OK"] }), "dialog-message")}>MessageBox</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "dialog_show_error_box", title: "Suji Error", content: "Error box from demo" }), "dialog-error")}>ErrorBox</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "dialog_show_open_dialog", properties: ["openFile", "openDirectory"] }), "dialog-open")}>OpenDialog</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "dialog_show_save_dialog", defaultPath: "/tmp/suji-demo.txt" }), "dialog-save")}>SaveDialog</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => {
              const cancel = suji.on("tray:menu-click", (data: unknown) => log(`  [tray:menu-click] ${S(data)}`));
              (window as any).__trayClickCancel = cancel;
              log("tray:menu-click listener ON");
            }}>Tray event ON</button>
            <button className="zig" onClick={() => call(async () => {
              const created = await core({ cmd: "tray_create", title: "S", tooltip: "Suji demo tray" }) as { trayId?: number };
              (window as any).__trayId = created.trayId;
              return created;
            }, "tray-create")}>Tray create</button>
            <button className="zig" onClick={() => call(() => core({
              cmd: "tray_set_menu",
              trayId: (window as any).__trayId ?? 1,
              items: [
                { label: "Demo Click", click: "demo-click" },
                { type: "separator" },
                { label: "Second", click: "second-click" },
              ],
            }), "tray-menu")}>Tray menu</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "tray_destroy", trayId: (window as any).__trayId ?? 1 }), "tray-destroy")}>Tray destroy</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => {
              const cancel = suji.on("notification:click", (data: unknown) => log(`  [notification:click] ${S(data)}`));
              (window as any).__notificationClickCancel = cancel;
              log("notification:click listener ON");
            }}>Notification event ON</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "notification_is_supported" }), "notification-supported")}>Notification supported</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "notification_request_permission" }), "notification-permission")}>Notification permission</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "notification_show", title: "Suji Demo", body: "Notification from demo", silent: false }), "notification-show")}>Notification show</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => {
              const cancel = suji.on("menu:click", (data: unknown) => log(`  [menu:click] ${S(data)}`));
              (window as any).__menuClickCancel = cancel;
              log("menu:click listener ON");
            }}>Menu event ON</button>
            <button className="zig" onClick={() => call(() => core({
              cmd: "menu_set_application_menu",
              items: [
                {
                  label: "Demo",
                  submenu: [
                    { label: "Run Demo Action", click: "demo-action" },
                    { type: "checkbox", label: "Enabled", click: "demo-enabled", checked: true },
                    { type: "separator" },
                    { label: "Nested", submenu: [{ label: "Nested Action", click: "nested-action" }] },
                  ],
                },
              ],
            }), "menu-set")}>Set app menu</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "menu_reset_application_menu" }), "menu-reset")}>Reset app menu</button>
          </div>
          <div className="buttons" style={{ marginTop: 6 }}>
            <button className="zig" onClick={() => call(async () => {
              const base = `/tmp/suji-demo-${Date.now()}`;
              const file = `${base}/hello.txt`;
              const mkdir = await core({ cmd: "fs_mkdir", path: base, recursive: true });
              const write = await core({ cmd: "fs_write_file", path: file, text: "hello\nfrom demo" });
              const read = await core({ cmd: "fs_read_file", path: file });
              const stat = await core({ cmd: "fs_stat", path: file });
              const readdir = await core({ cmd: "fs_readdir", path: base });
              return { base, mkdir, write, read, stat, readdir };
            }, "fs-roundtrip")}>FS round-trip</button>
            <button className="zig" onClick={() => call(() => core({ cmd: "fs_read_file", path: "/tmp/suji-demo-missing.txt" }), "fs-missing")}>FS missing file</button>
          </div>
        </section>

        <section>
          <h3>9. Stress</h3>
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

        <section>
          <h3>WebContentsView (Phase 17-A)</h3>
          <div className="row">
            <button onClick={async () => {
              if (redId !== null) {
                await core({ cmd: "destroy_view", viewId: redId });
                log(`red destroyed: ${redId}`);
                setRedId(null);
                return;
              }
              const html = `<body style="margin:0;background:crimson;color:white;font:32px sans-serif;display:flex;align-items:center;justify-content:center">RED VIEW</body>`;
              const r = await core({
                cmd: "create_view",
                hostId: HOST_ID,
                url: `data:text/html,${encodeURIComponent(html)}`,
                x: 80, y: 240, width: 320, height: 200,
              }) as { viewId?: number; error?: string };
              if (r.viewId) { setRedId(r.viewId); log(`red created: ${r.viewId}`); }
              else log(`red error: ${S(r)}`);
            }}>{redId !== null ? "× Destroy Red" : "+ Add Red"}</button>
            <button onClick={async () => {
              if (blueId !== null) {
                await core({ cmd: "destroy_view", viewId: blueId });
                log(`blue destroyed: ${blueId}`);
                setBlueId(null);
                return;
              }
              const html = `<body style="margin:0;background:royalblue;color:white;font:32px sans-serif;display:flex;align-items:center;justify-content:center">BLUE VIEW</body>`;
              const r = await core({
                cmd: "create_view",
                hostId: HOST_ID,
                url: `data:text/html,${encodeURIComponent(html)}`,
                x: 220, y: 280, width: 320, height: 200,
              }) as { viewId?: number; error?: string };
              if (r.viewId) { setBlueId(r.viewId); log(`blue created: ${r.viewId}`); }
              else log(`blue error: ${S(r)}`);
            }}>{blueId !== null ? "× Destroy Blue" : "+ Add Blue"}</button>
            <button onClick={async () => {
              if (redId === null || blueId === null) { log("need both red+blue"); return; }
              const r = await core({ cmd: "get_child_views", hostId: HOST_ID }) as { viewIds: number[] };
              const top = r.viewIds[r.viewIds.length - 1];
              const target = top === redId ? blueId : redId;
              await core({ cmd: "set_top_view", hostId: HOST_ID, viewId: target });
              log(`top now: ${target}`);
            }}>Swap Top</button>
            <button onClick={async () => {
              const r = await core({ cmd: "get_child_views", hostId: HOST_ID }) as { viewIds: number[] };
              log(`getChildViews: [${r.viewIds.join(", ")}]`);
            }}>get_child_views</button>
          </div>
          <div style={{fontSize:11,color:"#888",marginTop:6}}>
            host=window#{HOST_ID} · red={redId ?? "—"} · blue={blueId ?? "—"}
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
