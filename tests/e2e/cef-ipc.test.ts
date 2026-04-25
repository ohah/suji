/**
 * CEF IPC E2E Tests
 *
 * Suji 앱을 CEF 모드로 실행한 상태에서 CDP(Chrome DevTools Protocol)로 연결하여
 * 프론트엔드 ↔ 백엔드 IPC가 정상 동작하는지 검증합니다.
 *
 * 실행 방법:
 *   1. cd examples/multi-backend && ../../zig-out/bin/suji dev --cef
 *   2. bun test tests/e2e/cef-ipc.test.ts
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

// 헬퍼: invoke 호출
const invoke = (channel: string, data = {}, options = {}) =>
  page.evaluate(
    ([c, d, o]) => (window as any).__suji__.invoke(c, d, o),
    [channel, data, options] as const
  );

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    // 200회 chain stress가 부하 환경에서 10s 초과 → 30s로. flaky 회귀 방지.
    protocolTimeout: 30000,
    // CEF 실제 창 크기를 그대로 사용 (puppeteer 기본 800x600 emulation 비활성).
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

// ============================================
// 1. 기본 연결 확인
// ============================================

describe("CEF connection", () => {
  test("page is loaded", () => {
    expect(page.url()).toContain("localhost");
  });

  test("window.__suji__ exists", async () => {
    const type = await page.evaluate(() => typeof (window as any).__suji__);
    expect(type).toBe("object");
  });

  test("__suji__ has invoke/emit/on", async () => {
    const keys = await page.evaluate(() =>
      Object.keys((window as any).__suji__)
    );
    expect(keys).toContain("invoke");
    expect(keys).toContain("emit");
    expect(keys).toContain("on");
  });
});

// ============================================
// 2. invoke — 자동 라우팅
// ============================================

describe("invoke: auto-routing", () => {
  test("invoke('add', {a:10, b:20}) → Zig", async () => {
    const result: any = await invoke("add", { a: 10, b: 20 });
    expect(result.from).toBe("zig");
    expect(result.result.result).toBe(30);
  });

  test("invoke('info') → Zig", async () => {
    const result: any = await invoke("info");
    expect(result.from).toBe("zig");
    expect(result.result.runtime).toBe("zig");
  });

  test("invoke('ping') → 에러 (중복 채널)", async () => {
    const result = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping").catch((e: any) => "ERR:" + e)
    );
    expect(String(result)).toContain("ERR:");
  });
});

// ============================================
// 3. invoke — target 지정 (ping/greet x zig/rust/go)
// ============================================

describe("invoke: target", () => {
  for (const target of ["zig", "rust", "go"]) {
    test(`ping → ${target}`, async () => {
      const result: any = await invoke("ping", {}, { target });
      expect(result.from).toBe(target);
    });
  }

  for (const target of ["zig", "rust", "go"]) {
    test(`greet → ${target}`, async () => {
      const result: any = await invoke("greet", { name: "E2E" }, { target });
      expect(result.from).toBe(target);
    });
  }
});

// ============================================
// 4. Cross-backend 호출
// ============================================

describe("cross-backend", () => {
  const cases = [
    { cmd: "call_rust", target: "zig", from: "zig", nested: "rust_said" },
    { cmd: "call_go", target: "zig", from: "zig", nested: "go_said" },
    { cmd: "call_go", target: "rust", from: "rust", nested: "go_said" },
    { cmd: "call_rust", target: "go", from: "go", nested: "rust_said" },
  ];
  for (const { cmd, target, from, nested } of cases) {
    test(`${target} → ${nested.replace("_said", "")} (${cmd})`, async () => {
      const result: any = await invoke(cmd, {}, { target });
      expect(result.from).toBe(from);
      expect(result[nested]).toBeDefined();
    });
  }
});

// ============================================
// 5. Collab (크로스 백엔드 체인)
// ============================================

describe("collab", () => {
  test("zig leads collab", async () => {
    const result: any = await invoke("collab", { data: "e2e test" }, { target: "zig" });
    expect(result.from).toBe("zig");
    expect(result.rust_collab).toBeDefined();
    expect(result.go_collab).toBeDefined();
  });

  test("rust leads collab", async () => {
    const result: any = await invoke("collab", { data: "e2e test" }, { target: "rust" });
    expect(result.from).toBe("rust");
    expect(result.go_stats).toBeDefined();
  });
});

// ============================================
// 6. Events (on/emit)
// ============================================

describe("events", () => {
  test("emit → on 수신", async () => {
    const result = await page.evaluate(() => {
      return new Promise<string>((resolve, reject) => {
        const s = (window as any).__suji__;
        const timer = setTimeout(() => reject(new Error("timeout")), 5000);
        s.on("e2e-test-event", (data: any) => {
          clearTimeout(timer);
          resolve(JSON.stringify(data));
        });
        s.emit("e2e-test-event", JSON.stringify({ msg: "hello" }));
      });
    });
    expect(result).toContain("hello");
  });

  test("backend emit_event → JS on 수신", async () => {
    const result = await page.evaluate(() => {
      return new Promise<string>((resolve, reject) => {
        const s = (window as any).__suji__;
        const timer = setTimeout(() => reject(new Error("timeout")), 5000);
        s.on("zig-event", (data: any) => {
          clearTimeout(timer);
          resolve(JSON.stringify(data));
        });
        s.invoke("emit_event", {}, { target: "zig" }).catch(reject);
      });
    });
    expect(result).toBeDefined();
  });
});

// ============================================
// 7. Fanout
// ============================================

describe("fanout", () => {
  test("ping all backends", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.fanout("zig,rust,go", '{"cmd":"ping"}')
    );
    expect(result.fanout).toHaveLength(3);
  });
});

// ============================================
// 8. Core
// ============================================

describe("core", () => {
  test("core_info returns backend list", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.core('{"cmd":"core_info"}')
    );
    expect(result.from).toBe("zig-core");
    expect(result.backends).toBeArray();
    expect(result.backends.length).toBeGreaterThanOrEqual(3);
  });
});

// ============================================
// 9. Stress
// ============================================

describe("stress", () => {
  test("30 concurrent invoke calls", async () => {
    const result = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const promises = [];
      for (let i = 0; i < 10; i++) {
        promises.push(s.invoke("ping", {}, { target: "zig" }));
        promises.push(s.invoke("ping", {}, { target: "rust" }));
        promises.push(s.invoke("ping", {}, { target: "go" }));
      }
      const results = await Promise.allSettled(promises);
      return results.filter((r: any) => r.status === "fulfilled").length;
    });
    expect(result).toBe(30);
  });

  test("mixed operations (invoke + fanout + core)", async () => {
    const result = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const results = await Promise.allSettled([
        s.invoke("ping", {}, { target: "zig" }),
        s.invoke("ping", {}, { target: "rust" }),
        s.invoke("ping", {}, { target: "go" }),
        s.invoke("add", { a: 1, b: 2 }),
        s.fanout("zig,rust,go", '{"cmd":"ping"}'),
        s.core('{"cmd":"core_info"}'),
      ]);
      return results.filter((r: any) => r.status === "fulfilled").length;
    });
    expect(result).toBe(6);
  });
});

// ============================================
// Node.js 양방향 크로스 호출 깊은 재귀 체인
// 체인: node → zig → rust → go → node → ... (4주기 반복)
// 목적: Node의 invokeSync가 drain_ipc_queue_inline을 통해 재귀 콜백을 안전하게
// 처리하는지, 모든 백엔드가 깊이 관계없이 값을 정확히 전달하는지 검증.
// ============================================
// ============================================
// 체인: node → zig → rust → go → node → ... (4주기 반복)
// 목적: Node invokeSync가 재귀 콜백을 안전하게 처리하는지 검증.
// ============================================
describe("stress: deep recursive cross-backend chain", () => {
  test("depth=0 (node base case)", async () => {
    const resp: any = await invoke("node-stress", { depth: 0 });
    expect(resp.base).toBe("node");
    expect(resp.remaining).toBe(0);
  });

  test("depth=1 (node→zig base)", async () => {
    const resp: any = await invoke("node-stress", { depth: 1 });
    expect(resp.at).toBe("node");
    expect(resp.child.base).toBe("zig");
  });

  test("depth=4 (full cycle, Node 재진입 없음)", async () => {
    // node(start)→zig→rust→go→node(base). 마지막 node는 base case라 재진입 없음.
    const resp: any = await invoke("node-stress", { depth: 4 });
    expect(resp.at).toBe("node");
    expect(resp.child.at).toBe("zig");
    expect(resp.child.child.at).toBe("rust");
    expect(resp.child.child.child.at).toBe("go");
    expect(resp.child.child.child.child.base).toBe("node");
  });

  test("depth=5 (Node 재진입 경로 첫 진입)", async () => {
    // node(start) → zig → rust → go → node(recur) → zig(base). 중간 node가 재귀.
    const resp: any = await invoke("node-stress", { depth: 5 });
    expect(resp.at).toBe("node");
    expect(resp.child.at).toBe("zig");
    expect(resp.child.child.at).toBe("rust");
    expect(resp.child.child.child.at).toBe("go");
    expect(resp.child.child.child.child.at).toBe("node"); // 재진입 node
    expect(resp.child.child.child.child.child.base).toBe("zig");
  });

  test("depth=20 (5 cycles, Node 재진입 여러 번)", async () => {
    const resp: any = await invoke("node-stress", { depth: 20 });
    let cur: any = resp;
    const chain: string[] = [];
    for (let i = 0; i < 20; i++) {
      expect(cur.at).toBeDefined();
      chain.push(cur.at);
      cur = cur.child;
    }
    expect(cur.base).toBeDefined();
    const expected = ["node", "zig", "rust", "go"];
    for (let i = 0; i < 20; i++) {
      expect(chain[i]).toBe(expected[i % 4]);
    }
  });

  test("depth=40 (10 cycles, 재진입 스트레스)", async () => {
    const resp: any = await invoke("node-stress", { depth: 40 });
    let cur: any = resp;
    let count = 0;
    while (cur?.at) {
      count += 1;
      cur = cur.child;
    }
    expect(count).toBe(40);
    expect(cur.base).toBeDefined();
  });

  test("Rust 시작 체인: rust-stress depth=3 (rust→go→node→zig base)", async () => {
    // Node를 중간에만 거치고 재진입은 없는 경로
    const resp: any = await invoke("rust-stress", { depth: 3 });
    expect(resp.at).toBe("rust");
    expect(resp.child.at).toBe("go");
    expect(resp.child.child.at).toBe("node");
    expect(resp.child.child.child.base).toBe("zig");
  });

  test("연속 독립 체인 10회 (깊이 4)", async () => {
    // 재진입 없는 depth=4를 10번 순차 호출해 메모리/IPC 누수 없는지 확인
    const results = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const out: string[] = [];
      for (let i = 0; i < 10; i++) {
        const r: any = await s.invoke("node-stress", { depth: 4 });
        out.push(r?.child?.child?.child?.child?.base ?? "fail");
      }
      return out;
    });
    expect(results.filter((r: string) => r === "node")).toHaveLength(10);
  });

  test("10 concurrent depth=4 invocations", async () => {
    // 동시 IPC가 교차돼도 각 응답이 자기 correlation id로 매칭되는지
    const results = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const promises = [];
      for (let i = 0; i < 10; i++) {
        promises.push(s.invoke("node-stress", { depth: 4 }));
      }
      const settled = await Promise.allSettled(promises);
      return settled.map((r: any) =>
        r.status === "fulfilled" ? "ok" : String(r.reason)
      );
    });
    expect(results.filter((r: string) => r === "ok")).toHaveLength(10);
  });

  test("다른 스레드 재진입: Rust가 std::thread로 Node 호출 (Node 한가한 상태)", async () => {
    // Node main이 block되지 않은 상태에서 sub-thread가 Node queue에 push.
    // Node event loop가 uv_async_send로 깨어나 정상 처리 → deadlock 없음.
    const resp: any = await invoke("rust-thread-node");
    expect(resp.node_resp).toContain("pong");
  }, 15000);

  test("다른 스레드 재진입 + Node main block: deadlock 재현/수정 검증", async () => {
    // 1) JS → Node main(invokeSync "rust-thread-node") 진입 → Node main thread block
    // 2) Rust handler가 std::thread::spawn으로 sub-thread 생성, 거기서 core.invoke("node")
    // 3) Node main이 block 중이면 queue drain 안 됨 → 30s timeout (수정 전)
    // 수정 후: js_suji_invoke_sync가 워커 스레드에서 g_core.invoke 실행 + 메인이 polling drain
    const resp: any = await invoke("node-thread-deadlock");
    expect(resp.result).toBeDefined();
    // 정상 응답이면 안쪽 Rust가 Node를 호출해서 ping 응답을 받은 것
    expect(JSON.stringify(resp)).toContain("pong");
  }, 15000);

  test("응답 메모리 누수 회귀 방지: 200회 체인 호출", async () => {
    // coreFree가 no-op였던 시절엔 매 크로스 호출마다 응답 strdup이 leak됨.
    // depth=2 × 200회 = coreInvoke→coreFree 왕복 최소 400회.
    // 지금은 length-prefix header로 정상 해제되는지 확인 (실패 시 RSS 폭주/crash).
    // 5초 내 완료를 목표로 규모 조정.
    const success = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      let ok = 0;
      for (let i = 0; i < 200; i++) {
        const r: any = await s.invoke("node-stress", { depth: 2 });
        if (r?.child?.child?.base === "rust") ok += 1;
      }
      return ok;
    });
    expect(success).toBe(200);
  }, 15000);
});
