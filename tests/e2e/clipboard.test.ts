/**
 * Clipboard E2E — `suji.clipboard.{readText, writeText, clear}` 종합 검증.
 *
 * 호스트 macOS의 pbcopy/pbpaste 통해 시스템 클립보드 양방향 통신:
 *   - 기본: write/read/clear round-trip
 *   - 길이 한도: MAX_RESPONSE(16384) boundary
 *   - JSON wire 안전성: 메타문자 + escape sequence
 *   - Unicode: BMP + non-BMP + 이모지 ZWJ + RTL
 *   - 스트레스: 200회 round-trip, Promise.all 동시
 *   - 다중 창: 창 A에서 write → 창 B에서 read
 *   - 라이프사이클: lazy init, repeated invocation
 *   - 누락 필드: text 없는 request → empty default
 *
 * 실행: tests/e2e/run-clipboard.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

async function pbcopy(text: string): Promise<void> {
  const proc = Bun.spawn(["pbcopy"], { stdin: "pipe" });
  proc.stdin.write(text);
  await proc.stdin.end();
  await proc.exited;
}

async function pbpaste(): Promise<string> {
  const proc = Bun.spawn(["pbpaste"], { stdout: "pipe" });
  await proc.exited;
  return await new Response(proc.stdout).text();
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

// ============================================
// 기본 write → host pbpaste
// ============================================

describe("Clipboard write → host pbpaste", () => {
  test("plain ASCII", async () => {
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: "hello-suji" });
    expect(r.success).toBe(true);
    expect(await pbpaste()).toBe("hello-suji");
  });

  test("multiline + tab + quotes + backslash 보존", async () => {
    const original = "line1\nline2\twith \"quote\" and \\backslash\\";
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(r.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("UTF-8 한글/이모지 BMP", async () => {
    const original = "안녕 Suji 🎉";
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(r.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("빈 문자열 write 후 pbpaste 빈 문자열", async () => {
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: "" });
    expect(r.success).toBe(true);
    expect(await pbpaste()).toBe("");
  });
});

// ============================================
// host pbcopy → read
// ============================================

describe("Host pbcopy → Clipboard read", () => {
  test("plain ASCII readback", async () => {
    await pbcopy("from-host-abc");
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe("from-host-abc");
  });

  test("multiline readback (escapeJsonStrFull 라운드트립)", async () => {
    const original = "host-line1\nhost-line2\there";
    await pbcopy(original);
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
  });

  test("quote/backslash readback", async () => {
    const original = 'a"b\\c"d';
    await pbcopy(original);
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
  });

  test("UTF-8 한글 readback", async () => {
    const original = "한글 텍스트 테스트";
    await pbcopy(original);
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
  });
});

// ============================================
// clear
// ============================================

describe("Clipboard clear", () => {
  test("clear 후 readText 빈 문자열", async () => {
    await pbcopy("seed-content");
    const before = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(before.text).toBe("seed-content");

    const cleared = await core<{ success: boolean }>({ cmd: "clipboard_clear" });
    expect(cleared.success).toBe(true);

    const after = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(after.text).toBe("");
  });

  test("clear 후 다시 write → read 정상 동작 (state corruption 없음)", async () => {
    await core({ cmd: "clipboard_clear" });
    const r1 = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: "after-clear" });
    expect(r1.success).toBe(true);
    const r2 = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r2.text).toBe("after-clear");
  });
});

// ============================================
// A. 길이 한도 (MAX_RESPONSE = 16384)
// ============================================

describe("길이 한도", () => {
  test("8KB 텍스트 round-trip 성공", async () => {
    const text = "x".repeat(8192);
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(text);
  });

  test("12KB 텍스트 round-trip 성공", async () => {
    const text = "y".repeat(12288);
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(text);
  });

  test("길이 한도 초과 (32KB) — 어딘가에서 잘리거나 실패하지만 crash X", async () => {
    const text = "z".repeat(32768);
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text });
    // 어떤 쪽이든 boolean — 처리 가능하면 true, 한도 초과면 false
    expect(typeof w.success).toBe("boolean");
  });

  test("read 결과가 길어도 응답 버퍼에 안전하게 들어감 (8KB)", async () => {
    await pbcopy("R".repeat(8192));
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text.length).toBeGreaterThanOrEqual(8000);
    expect(r.text.length).toBeLessThanOrEqual(8192);
  });
});

// ============================================
// B. JSON wire 안전성 — IPC 메타문자 round-trip
// ============================================

describe("JSON wire 안전성", () => {
  test("JSON 메타문자 (}, ], comma, colon, brackets) 그대로 보존", async () => {
    const original = '{"key":"value","arr":[1,2],"obj":{"x":"y"}}';
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);

    // round-trip via Suji read
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
  });

  test("이중 escape (\\\\\\\") 보존", async () => {
    const original = 'path\\\\to\\\\file with \\"escaped\\" quotes';
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("control char (\\u0001-\\u001F) preserve via \\u00XX", async () => {
    const original = "a\x01b\x07c\x1fd";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    // pbpaste 결과는 control char 그대로 포함
    expect(await pbpaste()).toBe(original);
  });

  test("text 끝이 backslash로 끝남 — 잘못된 escape 방어", async () => {
    const original = "trailing slash here \\";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("text가 통째로 backslash 시퀀스", async () => {
    const original = "\\\\\\\\";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("JSON injection 시도 (응답 형식 깨뜨리려 시도) — Suji read 정상", async () => {
    const original = '","leak":"data","fake":"';
    await pbcopy(original);
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
    // 기대치: r에 "leak"이나 "fake" 같은 leaked 키 없음 (객체 안 깨짐)
    expect((r as any).leak).toBeUndefined();
    expect((r as any).fake).toBeUndefined();
  });
});

// ============================================
// C. Unicode / i18n
// ============================================

describe("Unicode / i18n", () => {
  test("일본어 (히라가나/카타카나/한자)", async () => {
    const original = "こんにちは 世界 カタカナ";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("중국어 (간체/번체)", async () => {
    const original = "你好世界 — 簡體與繁體";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("RTL — 아랍어/히브리어", async () => {
    const original = "مرحبا עולם السلام";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("LTR + RTL 혼합", async () => {
    const original = "Hello مرحبا 안녕 שלום World";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("non-BMP 이모지 (4-byte UTF-8)", async () => {
    const original = "🎉 🚀 🦀 🐉 🌍";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("ZWJ 시퀀스 이모지 (👨‍👩‍👧‍👦, 🏳️‍🌈)", async () => {
    const original = "Family 👨‍👩‍👧‍👦 Pride 🏳️‍🌈";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });

  test("Unicode read-back via pbcopy (BMP + non-BMP)", async () => {
    const original = "한글 emoji 🎊 العربية 中文";
    await pbcopy(original);
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe(original);
  });

  test("결합 분음 부호 (combining marks)", async () => {
    const original = "café (e + ́) — naïve (i + ̈)";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text: original });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe(original);
  });
});

// ============================================
// D. 스트레스 / 메모리 누수
// ============================================

describe("스트레스", () => {
  test("200회 sequential round-trip — 누수/crash 없음", async () => {
    for (let i = 0; i < 200; i++) {
      const text = `iter-${i}`;
      const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text });
      expect(w.success).toBe(true);
      const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
      expect(r.text).toBe(text);
    }
  }, 60000);

  test("Promise.all 50회 동시 readText — 모두 일관된 응답", async () => {
    await core({ cmd: "clipboard_write_text", text: "concurrent-baseline" });
    const results = await Promise.all(
      Array.from({ length: 50 }, () => core<{ text: string }>({ cmd: "clipboard_read_text" })),
    );
    for (const r of results) {
      expect(r.text).toBe("concurrent-baseline");
    }
  });

  test("write/read/clear 인터리브 100회", async () => {
    for (let i = 0; i < 100; i++) {
      const op = i % 3;
      if (op === 0) {
        await core({ cmd: "clipboard_write_text", text: `mix-${i}` });
      } else if (op === 1) {
        await core({ cmd: "clipboard_read_text" });
      } else {
        await core({ cmd: "clipboard_clear" });
      }
    }
    // 마지막 상태 정상인지만 확인
    await core({ cmd: "clipboard_write_text", text: "final" });
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe("final");
  }, 30000);
});

// ============================================
// G. 다중 창 — windows.create 후 cross-window read/write
// ============================================

describe("다중 창 클립보드 공유", () => {
  test("create_window로 새 창 생성 + 새 창 windowId 유효 + (CDP target 잡으면) clipboard 공유", async () => {
    const sentinel = "cross-window-clipboard-test-" + Date.now();
    await core({ cmd: "clipboard_write_text", text: sentinel });

    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "Clipboard Test B",
      url: "http://localhost:5173/",
      width: 400,
      height: 300,
    });
    expect(created.windowId).toBeGreaterThan(0);

    // 새 창이 CDP에 노출될 수도/안 될 수도 — CEF가 runtime-created browser를 자동
    // attach 안 하는 환경 있음. 잡히면 read 검증, 안 잡히면 windowId만 회귀 가드.
    let newPage: Page | undefined;
    for (let attempt = 0; attempt < 10; attempt++) {
      await new Promise((res) => setTimeout(res, 500));
      const targets = browser.targets();
      for (const t of targets) {
        if (t.type() !== "page") continue;
        const p = await t.page();
        if (!p || p === page) continue;
        if (!p.url().includes("localhost")) continue;
        try {
          const ready = await p.evaluate(() => !!(window as any).__suji__);
          if (ready) {
            newPage = p;
            break;
          }
        } catch {}
      }
      if (newPage) break;
    }

    if (newPage) {
      const readFromB = await newPage.evaluate(async () => {
        const bridge = (window as any).__suji__;
        const r = await bridge.core(JSON.stringify({ cmd: "clipboard_read_text" }));
        return r.text;
      });
      expect(readFromB).toBe(sentinel);
    } else {
      // CDP target 못 잡았어도 system clipboard는 동일 — 시스템 pbpaste로 공유 검증.
      expect(await pbpaste()).toBe(sentinel);
    }
  }, 30000);
});

// ============================================
// H. 라이프사이클 / 반복 호출
// ============================================

describe("라이프사이클", () => {
  test("동일 호출 5번 반복 — 결과 일관", async () => {
    await core({ cmd: "clipboard_write_text", text: "repeat-test" });
    for (let i = 0; i < 5; i++) {
      const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
      expect(r.text).toBe("repeat-test");
    }
  });

  test("write-clear-write 시퀀스 누수 없음", async () => {
    for (let i = 0; i < 20; i++) {
      await core({ cmd: "clipboard_write_text", text: `seq-${i}` });
      await core({ cmd: "clipboard_clear" });
    }
    // 최종 clear 후 read 빈 문자열
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe("");
  });
});

// ============================================
// J. 누락 / 잘못된 필드
// ============================================

describe("누락 / 잘못된 필드", () => {
  test("text 필드 없는 write → empty 처리", async () => {
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_text" });
    expect(w.success).toBe(true);
    expect(await pbpaste()).toBe("");
  });

  test("read는 인자 없어도 동작", async () => {
    await pbcopy("no-arg-needed");
    const r = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(r.text).toBe("no-arg-needed");
  });

  test("clear는 인자 없어도 동작", async () => {
    const c = await core<{ success: boolean }>({ cmd: "clipboard_clear" });
    expect(c.success).toBe(true);
  });
});
