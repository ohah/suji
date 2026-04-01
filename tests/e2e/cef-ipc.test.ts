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

beforeAll(async () => {
  browser = await puppeteer.connect({ browserURL: "http://localhost:9222" });
  const pages = await browser.pages();
  page = pages[0];
});

afterAll(async () => {
  await browser?.disconnect();
});

// ============================================
// 1. 기본 연결 확인
// ============================================

describe("CEF connection", () => {
  test("page is loaded", async () => {
    const url = page.url();
    expect(url).toContain("localhost");
  });

  test("window.__suji__ exists", async () => {
    const type = await page.evaluate(() => typeof (window as any).__suji__);
    expect(type).toBe("object");
  });

  test("__suji__ has invoke/emit/on", async () => {
    const keys = await page.evaluate(() => Object.keys((window as any).__suji__));
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
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("add", { a: 10, b: 20 })
    );
    expect(result.from).toBe("zig");
    expect(result.result.result).toBe(30);
  });

  test("invoke('info') → Zig", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("info")
    );
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
// 3. invoke — target 지정
// ============================================

describe("invoke: target", () => {
  test("ping → zig", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping", {}, { target: "zig" })
    );
    expect(result.from).toBe("zig");
  });

  test("ping → rust", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping", {}, { target: "rust" })
    );
    expect(result.from).toBe("rust");
  });

  test("ping → go", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping", {}, { target: "go" })
    );
    expect(result.from).toBe("go");
  });

  test("greet → zig", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("greet", { name: "E2E" }, { target: "zig" })
    );
    expect(result.from).toBe("zig");
    expect(result.result.greeting).toContain("Hello");
  });

  test("greet → rust", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("greet", { name: "E2E" }, { target: "rust" })
    );
    expect(result.from).toBe("rust");
  });

  test("greet → go", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("greet", { name: "E2E" }, { target: "go" })
    );
    expect(result.from).toBe("go");
  });
});

// ============================================
// 4. Cross-backend 호출
// ============================================

describe("cross-backend", () => {
  test("zig → rust (call_rust)", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("call_rust", {}, { target: "zig" })
    );
    expect(result.from).toBe("zig");
    expect(result.rust_said.from).toBe("rust");
  });

  test("zig → go (call_go)", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("call_go", {}, { target: "zig" })
    );
    expect(result.from).toBe("zig");
    expect(result.go_said.from).toBe("go");
  });

  test("rust → go (call_go)", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("call_go", {}, { target: "rust" })
    );
    expect(result.from).toBe("rust");
    expect(result.go_said.from).toBe("go");
  });

  test("go → rust (call_rust)", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("call_rust", {}, { target: "go" })
    );
    expect(result.from).toBe("go");
    expect(result.rust_said.from).toBe("rust");
  });
});

// ============================================
// 5. Collab (크로스 백엔드 체인)
// ============================================

describe("collab", () => {
  test("zig leads collab", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("collab", { data: "e2e test" }, { target: "zig" })
    );
    expect(result.from).toBe("zig");
    expect(result.rust_collab).toBeDefined();
    expect(result.go_collab).toBeDefined();
  });

  test("rust leads collab", async () => {
    const result: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("collab", { data: "e2e test" }, { target: "rust" })
    );
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
      return new Promise<string>((resolve) => {
        const s = (window as any).__suji__;
        s.on("e2e-test-event", (data: any) => {
          resolve(JSON.stringify(data));
        });
        // emit은 백엔드 EventBus를 거쳐 JS로 돌아옴
        s.emit("e2e-test-event", JSON.stringify({ msg: "hello" }));
      });
    });
    expect(result).toContain("hello");
  });

  test("backend emit_event → JS on 수신", async () => {
    const result = await page.evaluate(() => {
      return new Promise<string>((resolve, reject) => {
        const s = (window as any).__suji__;
        s.on("zig-event", (data: any) => {
          resolve(JSON.stringify(data));
        });
        s.invoke("emit_event", {}, { target: "zig" }).catch(reject);
        // 타임아웃
        setTimeout(() => reject("timeout"), 5000);
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
      const results = await Promise.all(promises);
      return results.length;
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
