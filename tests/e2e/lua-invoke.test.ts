/**
 * Lua backend E2E — vendored Lua 5.4 + bundled cjson.
 *
 * examples/lua-backend (단일 Lua 백엔드)에서 suji dev 실행 후 CDP 로 연결하여
 * frontend invoke() ↔ Lua handler 왕복과 cjson encode/decode 를 검증한다.
 * 요청은 {cmd:<channel>, ...payload} 로 직렬화되어 Lua handler 의 request_json
 * 인자로 전달되고, handler 는 cjson.encode 결과(JSON 문자열)를 반환한다.
 *
 * 실행: bash tests/e2e/run-lua-e2e.sh
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

describe("Lua backend invoke (vendored Lua 5.4 + cjson)", () => {
  test("ping → {runtime:'lua', msg:'pong'}", async () => {
    const r: any = await invoke("ping");
    expect(r.runtime).toBe("lua");
    expect(r.msg).toBe("pong");
  });

  test("echo: cjson decode/encode roundtrip", async () => {
    const r: any = await invoke("echo", { message: "hello from frontend", value: 42 });
    expect(r.runtime).toBe("lua");
    // 요청은 {cmd:"echo", ...payload} 로 직렬화되어 전달된다.
    expect(r.echo.cmd).toBe("echo");
    expect(r.echo.message).toBe("hello from frontend");
    expect(r.echo.value).toBe(42);
    expect(r.value).toBe(42);
  });

  test("cjson handles nested objects, arrays, unicode, floats", async () => {
    const payload = { nested: { a: [1, 2, 3], s: "한글/emoji😀" }, n: -3.14 };
    const r: any = await invoke("echo", payload);
    expect(r.echo.nested.a).toEqual([1, 2, 3]);
    expect(r.echo.nested.s).toBe("한글/emoji😀");
    expect(r.echo.n).toBeCloseTo(-3.14);
  });

  test("concurrent invoke stress (50 parallel) — mutex serialization stable", async () => {
    const results = await page.evaluate(async () => {
      const s = (window as any).__suji__;
      const calls = Array.from({ length: 50 }, (_, i) => s.invoke("echo", { i }));
      const settled = await Promise.all(calls);
      return settled.map((r: any) => ({ runtime: r.runtime, i: r.echo?.i }));
    });
    expect(results).toHaveLength(50);
    results.forEach((r: { runtime: string; i: number }, i: number) => {
      expect(r.runtime).toBe("lua");
      expect(r.i).toBe(i);
    });
  });

  // suji.send (outbound 이벤트 발신): lua handler 가 send → 프론트 on 수신.
  test("suji.send: lua emits 'lua-event' → frontend on receives", async () => {
    const result = await page.evaluate(
      () =>
        new Promise<string>((resolve, reject) => {
          const s = (window as any).__suji__;
          const timer = setTimeout(() => reject(new Error("timeout")), 5000);
          s.on("lua-event", (data: unknown) => {
            clearTimeout(timer);
            resolve(JSON.stringify(data));
          });
          s.invoke("emit-test").catch(reject);
        }),
    );
    expect(result).toContain("lua");
  });

  // suji.on (outbound 이벤트 수신): 프론트 emit → lua on 콜백 → lua send 로 에코.
  test("suji.on: frontend emit → lua on → 'lua-echo' back", async () => {
    const result = await page.evaluate(
      () =>
        new Promise<string>((resolve, reject) => {
          const s = (window as any).__suji__;
          const timer = setTimeout(() => reject(new Error("timeout")), 5000);
          s.on("lua-echo", (data: unknown) => {
            clearTimeout(timer);
            resolve(JSON.stringify(data));
          });
          s.emit("from-frontend", JSON.stringify({ hello: "from-js" }));
        }),
    );
    expect(result).toContain("from-js");
  });
});
