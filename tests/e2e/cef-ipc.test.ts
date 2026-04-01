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
    protocolTimeout: 10000,
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
