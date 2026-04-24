/**
 * Phase 2.5 Step 1 — `__window` wire-level 자동 주입 E2E.
 *
 * 프론트엔드에서 `__suji__.invoke`가 호출된 창의 WM id가 백엔드 request JSON에
 * 자동으로 `__window` 필드로 주입되는지를 검증 — 1/2/3개 창 모두.
 *
 * ## 전제
 *
 * 편의 스크립트: `bash tests/e2e/run-window-injection.sh`가 아래를 자동 세팅:
 *
 *   (1) `cd examples/multi-backend && SUJI_TRACE_IPC=1 <suji> dev | tee <LOG_PATH>`
 *       — `SUJI_TRACE_IPC=1` 환경변수가 켜져야 zig 백엔드의 ping 핸들러가
 *         `[zig/ping] raw={...}` 형태로 stderr에 출력함. `tee`로 stderr를 <LOG_PATH>에 미러링.
 *   (2) `SUJI_LOG=<LOG_PATH> bun test tests/e2e/window-injection.test.ts`
 *       — 기본 경로: `/tmp/suji-e2e.log`.
 *
 * ## 구현 노트 — puppeteer + CEF Alloy 신규 browser attach
 *
 * `puppeteer.connect({ browserURL })` 모드는 CDP 서버에서 신규 target을 discover만 하고
 * Page 객체 자동 attach는 하지 않음. `target.page()`는 null을 계속 반환. 대신
 * `target.createCDPSession()`으로 raw CDP 세션을 만들어 `Runtime.evaluate`로 JS를
 * 실행하면 신규 창에서도 호출 가능. main 창은 beforeAll에서 `browser.pages()[0]`로
 * 이미 attached 상태이므로 Page API 그대로 사용.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, {
  type Browser,
  type Page,
  type CDPSession,
  type Target,
} from "puppeteer-core";
import { readFileSync } from "node:fs";

const LOG_PATH = process.env.SUJI_LOG ?? "/tmp/suji-e2e.log";

let browser: Browser;
let page1: Page;

const PING_EXPR = `window.__suji__.invoke("ping", {}, { target: "zig" })`;

const pingViaPage = (p: Page) =>
  p.evaluate(() => (window as any).__suji__.invoke("ping", {}, { target: "zig" }));

const pingViaCDP = async (session: CDPSession) =>
  (
    await session.send("Runtime.evaluate", {
      expression: PING_EXPR,
      awaitPromise: true,
      returnByValue: true,
    })
  ).result.value;

const createWindow = (p: Page, title: string, name?: string) =>
  p.evaluate(
    (t, n) =>
      (window as any).__suji__.core(
        JSON.stringify({
          cmd: "create_window",
          title: t,
          url: "http://localhost:5173",
          ...(n ? { name: n } : {}),
        }),
      ),
    title,
    name ?? "",
  ) as Promise<{ windowId: number }>;

async function waitForNewPageTarget(excluded: Set<Target>, timeoutMs = 5000): Promise<Target> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const cand = browser.targets().find((t) => t.type() === "page" && !excluded.has(t));
    if (cand) return cand;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("new page target not discovered in time");
}

function readLogTail(path: string, startOffset: number): string {
  try {
    return readFileSync(path, "utf-8").slice(startOffset);
  } catch {
    return "";
  }
}

function logLength(path: string): number {
  try {
    return readFileSync(path, "utf-8").length;
  } catch {
    return 0;
  }
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 10000,
  });
  const pages = await browser.pages();
  const main = pages.find((p) => p.url().startsWith("http://localhost"));
  if (!main) {
    throw new Error(
      "main window (localhost) not found — is `suji dev` running with DevTools on :9222?",
    );
  }
  page1 = main;
  page1.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("Phase 2.5 — __window wire injection (1~3 windows)", () => {
  test("1개 창: 메인(id=1) ping → __window:1 주입", async () => {
    const before = logLength(LOG_PATH);
    const resp = await pingViaPage(page1);
    expect(resp).toBeDefined();

    await new Promise((r) => setTimeout(r, 300));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(
      /\[zig\/ping\] window\.id=1 name=\S* raw=\{"cmd":"ping","__window":1(?:,"__window_name":"[^"]*")?\}/,
    );
  });

  test("2개 창: 각 창에서 ping → 서로 다른 __window id 주입", async () => {
    const excluded = new Set<Target>([page1.target()]);
    const created = await createWindow(page1, "Window-2");
    expect(created.windowId).toBeGreaterThanOrEqual(2);

    const target2 = await waitForNewPageTarget(excluded);
    const cdp2 = await target2.createCDPSession();

    const before = logLength(LOG_PATH);
    await pingViaPage(page1);
    await pingViaCDP(cdp2);
    await new Promise((r) => setTimeout(r, 500));

    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(
      /\[zig\/ping\] window\.id=1 name=\S* raw=\{"cmd":"ping","__window":1(?:,"__window_name":"[^"]*")?\}/,
    );
    expect(tail).toMatch(
      new RegExp(
        `\\[zig/ping\\] window\\.id=${created.windowId} name=\\S* raw=\\{"cmd":"ping","__window":${created.windowId}(?:,"__window_name":"[^"]*")?\\}`,
      ),
    );
    expect(created.windowId).not.toBe(1);

    await cdp2.detach();
  }, 15000);

  test("2-arity 핸들러가 InvokeEvent.window.id / .name을 받음", async () => {
    // zig 백엔드 ping은 2-arity. 응답에 window_id + window_name 포함.
    const resp = (await pingViaPage(page1)) as { result: { window_id: number; window_name: string } };
    expect(resp.result.window_id).toBe(1);
    // main 창은 main.zig에서 .name = "main"으로 생성됨.
    expect(resp.result.window_name).toBe("main");
  });

  test("명명된 창: event.window.name이 wire + InvokeEvent를 거쳐 핸들러까지 전달", async () => {
    const excluded = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));
    const created = await createWindow(page1, "Settings", "settings");
    expect(created.windowId).toBeGreaterThanOrEqual(2);

    const target = await waitForNewPageTarget(excluded);
    const cdp = await target.createCDPSession();

    const before = logLength(LOG_PATH);
    const resp = (
      await pingViaCDP(cdp)
    ) as { result: { window_id: number; window_name: string } };
    expect(resp.result.window_id).toBe(created.windowId);
    expect(resp.result.window_name).toBe("settings");

    // stderr 로그에도 name 포함
    await new Promise((r) => setTimeout(r, 300));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/name=settings/);
    expect(tail).toMatch(/"__window_name":"settings"/);

    await cdp.detach();
  }, 15000);

  test("3개 창: 각 창에서 ping → distinct __window 세 값", async () => {
    const page1Target = page1.target();
    const excludedBefore = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));

    const created = await createWindow(page1, "Window-3");
    expect(created.windowId).toBeGreaterThanOrEqual(3);

    const target3 = await waitForNewPageTarget(excludedBefore);
    const cdp3 = await target3.createCDPSession();

    // page2: page1Target이 아니고 target3도 아닌 page 중 하나
    const page2Target = browser
      .targets()
      .find((t) => t.type() === "page" && t !== page1Target && t !== target3)!;
    expect(page2Target).toBeDefined();
    const cdp2 = await page2Target.createCDPSession();

    const before = logLength(LOG_PATH);
    await pingViaPage(page1);
    await pingViaCDP(cdp2);
    await pingViaCDP(cdp3);
    await new Promise((r) => setTimeout(r, 500));

    const tail = readLogTail(LOG_PATH, before);
    const ids = [...tail.matchAll(/"__window":(\d+)/g)].map((m) => Number(m[1]));
    const unique = new Set(ids);
    expect(unique.size).toBeGreaterThanOrEqual(3);
    expect(unique.has(1)).toBe(true);
    expect(unique.has(created.windowId)).toBe(true);

    await cdp2.detach();
    await cdp3.detach();
  }, 15000);
});

/**
 * Phase 2.5 — `send(..., {to: winId})` 타겟 라우팅 E2E.
 *
 * CEF의 v8 emit 바인딩 → CefProcessMessage의 3번째 int arg → main의 `handleBrowserEmit` →
 * `EventBus.emitTo` → `cef.evalJs(target, ...)` → 해당 창의 브라우저 하나만 dispatch.
 * 이 전체 경로가 살아 있어야 특정 창에만 이벤트가 도달하고 나머지는 받지 않는다.
 */
describe("Phase 2.5 — send {to: winId} 타겟 라우팅", () => {
  // 각 창에 __probes[] 배열 + 동일 채널 on-리스너를 설치.
  // page1/cdp2 양쪽에서 동일 JS를 실행 — 메인 창은 Page API, 새 창은 raw CDP.
  const installProbe = async (ch: string, p?: Page, session?: CDPSession) => {
    const script = `
      (function(){
        window.__probes = window.__probes || [];
        window.__suji__.on(${JSON.stringify(ch)}, function(data){
          window.__probes.push(data);
        });
      })();
    `;
    if (p) {
      await p.evaluate(script as any);
    } else if (session) {
      await session.send("Runtime.evaluate", { expression: script });
    }
  };

  const readProbes = async (p?: Page, session?: CDPSession): Promise<unknown[]> => {
    const expr = "JSON.stringify(window.__probes || [])";
    if (p) return JSON.parse(await p.evaluate(() => JSON.stringify((window as any).__probes || [])));
    if (session) {
      const r = await session.send("Runtime.evaluate", {
        expression: expr,
        returnByValue: true,
      });
      return JSON.parse(r.result.value as string);
    }
    return [];
  };

  const clearProbes = async (p?: Page, session?: CDPSession) => {
    const script = "window.__probes = [];";
    if (p) await p.evaluate(() => { (window as any).__probes = []; });
    else if (session) await session.send("Runtime.evaluate", { expression: script });
  };

  test("창1→창2 sendTo: 창2만 수신, 창1은 수신 안 함", async () => {
    // 새 창 생성
    const excluded = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));
    const created = await createWindow(page1, "Window-sendTo-2");
    expect(created.windowId).toBeGreaterThanOrEqual(2);
    const target2 = await waitForNewPageTarget(excluded);
    const cdp2 = await target2.createCDPSession();

    // 양쪽에 probe 설치
    const CH = "sendto-e2e";
    await installProbe(CH, page1);
    await installProbe(CH, undefined, cdp2);
    await clearProbes(page1);
    await clearProbes(undefined, cdp2);

    // 창 1에서 창 2로만 전송.
    // bridge emit JS wrapper가 자체적으로 JSON.stringify 하므로 object를 그대로 넘긴다.
    await page1.evaluate(
      (ch, winId) =>
        (window as any).__suji__.emit(ch, { msg: "to-2-only" }, winId),
      CH,
      created.windowId,
    );
    await new Promise((r) => setTimeout(r, 400));

    const p1 = await readProbes(page1);
    const p2 = await readProbes(undefined, cdp2);

    expect(p1).toEqual([]); // 창 1은 자기 자신이라도 target이 2면 수신 X
    expect(p2).toEqual([{ msg: "to-2-only" }]);

    await cdp2.detach();
  }, 20000);

  test("broadcast (target 생략): 모든 창이 수신", async () => {
    // 기존 창 재사용 — 이전 테스트에서 만든 창이 여전히 살아있음
    const pageTargets = browser.targets().filter((t) => t.type() === "page");
    expect(pageTargets.length).toBeGreaterThanOrEqual(2);
    const otherTarget = pageTargets.find((t) => t !== page1.target())!;
    const cdpOther = await otherTarget.createCDPSession();

    const CH = "broadcast-e2e";
    await installProbe(CH, page1);
    await installProbe(CH, undefined, cdpOther);
    await clearProbes(page1);
    await clearProbes(undefined, cdpOther);

    // to 생략 — 브로드캐스트
    await page1.evaluate(
      (ch) => (window as any).__suji__.emit(ch, { msg: "to-all" }),
      CH,
    );
    await new Promise((r) => setTimeout(r, 400));

    const p1 = await readProbes(page1);
    const p2 = await readProbes(undefined, cdpOther);

    expect(p1).toEqual([{ msg: "to-all" }]);
    expect(p2).toEqual([{ msg: "to-all" }]);

    await cdpOther.detach();
  }, 20000);

  // 각 언어 백엔드의 sendTo(SDK 경로)가 실제로 sender 창에만 이벤트를 전달하는지 검증.
  // SDK별 구현:
  //   Zig:  suji.sendTo(event.window.id, "zig-echo", ...)
  //   Rust: (core.emit_to)(win_id, "rust-echo", ...) — 예제가 SDK 없이 직접 FFI.
  //   Go:   C.core_emit_to(core, winID, "go-echo", ...) — 예제 직접 FFI.
  //   Node: sendTo(event.window.id, "node-echo", { ... }) — @suji/node.
  const backendCases = [
    { lang: "zig",  cmd: "zig-echo-to-sender",  channel: "zig-echo",  target: "zig" },
    { lang: "rust", cmd: "rust-echo-to-sender", channel: "rust-echo", target: "rust" },
    { lang: "go",   cmd: "go-echo-to-sender",   channel: "go-echo",   target: "go" },
    { lang: "node", cmd: "node-echo-to-sender", channel: "node-echo", target: "node" },
  ] as const;

  for (const { lang, cmd, channel, target } of backendCases) {
    test(`${lang} 백엔드 sendTo: 호출한 창에만 echo 도착`, async () => {
      const pageTargets = browser.targets().filter((t) => t.type() === "page");
      const otherTarget = pageTargets.find((t) => t !== page1.target())!;
      const cdpOther = await otherTarget.createCDPSession();

      await installProbe(channel, page1);
      await installProbe(channel, undefined, cdpOther);
      await clearProbes(page1);
      await clearProbes(undefined, cdpOther);

      // 1) page1 (id=1) → 이 창에만 echo 도착
      await page1.evaluate(
        (c, t) =>
          (window as any).__suji__.invoke(c, { text: "from-page1" }, { target: t }),
        cmd,
        target,
      );
      await new Promise((r) => setTimeout(r, 500));

      expect(await readProbes(page1)).toEqual([{ from: lang, text: "from-page1" }]);
      expect(await readProbes(undefined, cdpOther)).toEqual([]);

      await clearProbes(page1);
      await clearProbes(undefined, cdpOther);

      // 2) 다른 창 → 해당 창에만 echo 도착, page1은 받지 않음
      await cdpOther.send("Runtime.evaluate", {
        expression: `window.__suji__.invoke(${JSON.stringify(cmd)}, { text: "from-w2" }, { target: ${JSON.stringify(target)} })`,
        awaitPromise: true,
        returnByValue: true,
      });
      await new Promise((r) => setTimeout(r, 500));

      expect(await readProbes(page1)).toEqual([]);
      expect(await readProbes(undefined, cdpOther)).toEqual([{ from: lang, text: "from-w2" }]);

      await cdpOther.detach();
    }, 25000);
  }
});
