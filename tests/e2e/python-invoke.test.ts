/**
 * Python backend E2E — embedded CPython 3.13 (python-build-standalone) + GIL.
 *
 * examples/python-backend (단일 Python 백엔드)에서 suji dev 실행 후 CDP 로 연결하여
 * frontend invoke() ↔ Python handler 왕복과 표준 json 모듈 parse/serialize 를
 * 검증한다. 요청은 {cmd:<channel>, ...payload} 로 직렬화되어 Python handler 의
 * request_json 인자로 전달되고, handler 는 json.dumps 결과(JSON 문자열)를 반환한다.
 *
 * 실행: bash tests/e2e/run-python-e2e.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const invoke = (channel: string, data = {}, options = {}) =>
  page.evaluate(
    ([c, d, o]) => (window as any).__suji__.invoke(c, d, o),
    [channel, data, options] as const,
  );

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("Python backend invoke (embedded CPython 3.13 + GIL)", () => {
  test("ping → {runtime:'python', msg:'pong'}", async () => {
    const r: any = await invoke("ping");
    expect(r.runtime).toBe("python");
    expect(r.msg).toBe("pong");
  });

  test("backend → __core__ 도달: suji.invoke('__core__', screen_get_display_matching)", async () => {
    // Python 백엔드가 suji.invoke("__core__", ...) 로 네이티브 코어 cmd 를 호출 →
    // 모든 언어 백엔드가 코어 API 에 도달함을 실증(타입드 래퍼 없이 raw invoke).
    const r: any = await invoke("core-display-matching", { x: 10, y: 10, width: 100, height: 100 });
    expect(r.cmd).toBe("screen_get_display_matching");
    expect(typeof r.index).toBe("number");
  });

  test("backend → __core__ 도달: app.hasSingleInstanceLock", async () => {
    // Python 백엔드가 단일 인스턴스 락 cmd 에도 __core__ 로 도달(read-only has).
    const r: any = await invoke("core-single-instance", {});
    expect(r.cmd).toBe("app_has_single_instance_lock");
    expect(typeof r.locked).toBe("boolean");
  });

  test("echo: json decode/encode roundtrip", async () => {
    const r: any = await invoke("echo", { message: "hello from frontend", value: 42 });
    expect(r.runtime).toBe("python");
    // 요청은 {cmd:"echo", ...payload} 로 직렬화되어 전달된다.
    expect(r.echo.cmd).toBe("echo");
    expect(r.echo.message).toBe("hello from frontend");
    expect(r.echo.value).toBe(42);
    expect(r.value).toBe(42);
  });

  test("json handles nested objects, arrays, unicode, floats", async () => {
    const payload = { nested: { a: [1, 2, 3], s: "한글/emoji😀" }, n: -3.14 };
    const r: any = await invoke("echo", payload);
    expect(r.echo.nested.a).toEqual([1, 2, 3]);
    expect(r.echo.nested.s).toBe("한글/emoji😀");
    expect(r.echo.n).toBeCloseTo(-3.14);
  });

  test("concurrent invoke stress (50 parallel) — GIL serialization stable", async () => {
    const results = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const calls = Array.from({ length: 50 }, (_, i) => s.invoke("echo", { i }));
      const settled = await Promise.all(calls);
      return settled.map((r: any) => ({ runtime: r.runtime, i: r.echo?.i }));
    });
    expect(results).toHaveLength(50);
    results.forEach((r: { runtime: string; i: number }, i: number) => {
      expect(r.runtime).toBe("python");
      expect(r.i).toBe(i);
    });
  });

  // suji.send (outbound 이벤트 발신): python handler 가 send → 프론트 on 수신.
  test("suji.send: python emits 'python-event' → frontend on receives", async () => {
    const result = await page.evaluate(
      () =>
        new Promise<string>((resolve, reject) => {
          const s = (window as any).__suji__;
          const timer = setTimeout(() => reject(new Error("timeout")), 5000);
          s.on("python-event", (data: unknown) => {
            clearTimeout(timer);
            resolve(JSON.stringify(data));
          });
          s.invoke("emit-test").catch(reject);
        }),
    );
    expect(result).toContain("python");
  });

  // suji.on (outbound 이벤트 수신): 프론트 emit → python on 콜백 → python send 로 에코.
  test("suji.on: frontend emit → python on → 'python-echo' back", async () => {
    const result = await page.evaluate(
      () =>
        new Promise<string>((resolve, reject) => {
          const s = (window as any).__suji__;
          const timer = setTimeout(() => reject(new Error("timeout")), 5000);
          s.on("python-echo", (data: unknown) => {
            clearTimeout(timer);
            resolve(JSON.stringify(data));
          });
          s.emit("from-frontend", JSON.stringify({ hello: "from-js" }));
        }),
    );
    expect(result).toContain("from-js");
  });
});
