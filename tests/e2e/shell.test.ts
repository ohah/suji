/**
 * Shell E2E — `suji.shell.{openExternal, showItemInFolder, beep}` 종합 검증.
 *
 * 부수효과(브라우저 탭/Finder 윈도우/비프음)를 동반하는 valid 케이스는 RUN_DESTRUCTIVE=1
 * 환경변수가 있을 때만. 일반 모드는 invalid-input 분기 위주로 wiring 검증.
 *
 * 실행:
 *   ./tests/e2e/run-shell.sh                     # invalid-input + 사전 차단 검증
 *   RUN_DESTRUCTIVE=1 ./tests/e2e/run-shell.sh   # 전체 (브라우저+Finder+beep)
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

const runDestructive = process.env.RUN_DESTRUCTIVE === "1";

// 테스트용 path fixtures (beforeAll에서 생성, afterAll에서 정리)
const FIXTURE_BASE = "/tmp/suji-shell-e2e-fixtures";
const FIXTURE_FILE = `${FIXTURE_BASE}/file with spaces.txt`;
const FIXTURE_KOREAN = `${FIXTURE_BASE}/한글폴더`;
const FIXTURE_HIDDEN = `${FIXTURE_BASE}/.hidden-file`;
const FIXTURE_DEEP = `${FIXTURE_BASE}/a/b/c/d/e/f/g/leaf.txt`;
const FIXTURE_SYMLINK_TARGET = `${FIXTURE_BASE}/symlink-target`;
const FIXTURE_SYMLINK = `${FIXTURE_BASE}/symlink-link`;

async function shellRun(cmd: string, args: string[]): Promise<{ exitCode: number }> {
  const proc = Bun.spawn([cmd, ...args]);
  await proc.exited;
  return { exitCode: proc.exitCode ?? 0 };
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

  // path fixtures 생성
  await shellRun("rm", ["-rf", FIXTURE_BASE]);
  await shellRun("mkdir", ["-p", FIXTURE_BASE]);
  await shellRun("mkdir", ["-p", FIXTURE_KOREAN]);
  await shellRun("mkdir", ["-p", `${FIXTURE_BASE}/a/b/c/d/e/f/g`]);
  await shellRun("touch", [FIXTURE_FILE]);
  await shellRun("touch", [FIXTURE_HIDDEN]);
  await shellRun("touch", [FIXTURE_DEEP]);
  await shellRun("mkdir", ["-p", FIXTURE_SYMLINK_TARGET]);
  await shellRun("ln", ["-sfn", FIXTURE_SYMLINK_TARGET, FIXTURE_SYMLINK]);
});

afterAll(async () => {
  await shellRun("rm", ["-rf", FIXTURE_BASE]);
  await browser?.disconnect();
});

// ============================================
// shell.openExternal — invalid (no side effect)
// ============================================

describe("shell.openExternal — invalid input", () => {
  test("빈 문자열 → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external", url: "" });
    expect(r.success).toBe(false);
  });

  test("공백 포함 URL → URLWithString nil → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external", url: "not a valid url" });
    expect(r.success).toBe(false);
  });

  test("scheme 없는 plain text → 사전 차단 false (-50 dialog 회피)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: "noschemejustwords",
    });
    expect(r.success).toBe(false);
  });

  test("scheme 만 있고 host 없음 (\"https://\") → openURL 처리", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external", url: "https://" });
    // scheme은 있어 사전 차단 안 됨. NSWorkspace가 어떻게든 처리하므로 boolean.
    expect(typeof r.success).toBe("boolean");
  });

  test("URL 한도 초과 (5000자 path) → false", async () => {
    const longUrl = "https://example.com/" + "x".repeat(5000);
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external", url: longUrl });
    // SHELL_MAX_PATH=4096 초과 → nsStringFromSlice null → false
    expect(r.success).toBe(false);
  });

  test("탭/개행 포함 URL → URLWithString nil → false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: "https://exa\nmple.com",
    });
    expect(r.success).toBe(false);
  });

  test("\\: 만 (scheme 비어 있음) → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external", url: "://no-scheme" });
    expect(r.success).toBe(false);
  });
});

// ============================================
// shell.showItemInFolder — 경로 검증
// ============================================

describe("shell.showItemInFolder — invalid path", () => {
  test("존재하지 않는 경로 → false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: "/nonexistent/path/abc/xyz/123",
    });
    expect(r.success).toBe(false);
  });

  test("빈 경로 → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_show_item_in_folder", path: "" });
    expect(r.success).toBe(false);
  });

  test("path 한도 초과 (5000자) → false", async () => {
    const longPath = "/tmp/" + "x".repeat(5000);
    const r = await core<{ success: boolean }>({ cmd: "shell_show_item_in_folder", path: longPath });
    expect(r.success).toBe(false);
  });

  test("백슬래시/따옴표 포함 잘못된 경로 → 안전하게 false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: '/no\\such"weird/path',
    });
    expect(r.success).toBe(false);
  });
});

// ============================================
// shell.showItemInFolder — valid path (RUN_DESTRUCTIVE)
// ============================================

describe("shell.showItemInFolder — valid path (RUN_DESTRUCTIVE)", () => {
  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: /tmp reveal", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_show_item_in_folder", path: "/tmp" });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: 공백 포함 경로 reveal", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: FIXTURE_FILE,
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: 한글 폴더 reveal", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: FIXTURE_KOREAN,
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: hidden file reveal", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: FIXTURE_HIDDEN,
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: 깊은 트리(7-level) leaf 파일 reveal", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: FIXTURE_DEEP,
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: symbolic link target도 reveal", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: FIXTURE_SYMLINK,
    });
    expect(r.success).toBe(true);
  });
});

// ============================================
// shell.openExternal — 다양한 scheme (RUN_DESTRUCTIVE)
// ============================================

describe("shell.openExternal — URL schemes (RUN_DESTRUCTIVE)", () => {
  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: https://example.com → 기본 브라우저", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: "https://example.com",
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: file:// URL", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: `file://${FIXTURE_BASE}`,
    });
    expect(r.success).toBe(true);
  });

  test("URL with query/fragment/auth → scheme OK라 NSWorkspace 호출까지 도달", async () => {
    // RUN_DESTRUCTIVE=0이라도 사전 차단 안 됨 — scheme 있음. boolean 응답 확인까지만.
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: "https://user:pw@example.com/path?q=1&r=2#sec",
    });
    expect(typeof r.success).toBe("boolean");
  });
});

// ============================================
// shell.beep
// ============================================

describe("shell.beep", () => {
  test("응답 success=true (호출 자체는 항상 성공)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_beep" });
    expect(r.success).toBe(true);
  });

  test.skipIf(!runDestructive)("RUN_DESTRUCTIVE=1: 50회 연속 beep — crash 없음", async () => {
    for (let i = 0; i < 50; i++) {
      const r = await core<{ success: boolean }>({ cmd: "shell_beep" });
      expect(r.success).toBe(true);
    }
  });
});

// ============================================
// 스트레스
// ============================================

describe("스트레스", () => {
  test("100회 연속 invalid openExternal — 안정성", async () => {
    for (let i = 0; i < 100; i++) {
      const r = await core<{ success: boolean }>({
        cmd: "shell_open_external",
        url: `invalid-${i}`,
      });
      expect(r.success).toBe(false);
    }
  }, 30000);

  test("Promise.all 50회 동시 showItemInFolder (invalid)", async () => {
    const results = await Promise.all(
      Array.from({ length: 50 }, (_, i) =>
        core<{ success: boolean }>({ cmd: "shell_show_item_in_folder", path: `/no/${i}` }),
      ),
    );
    for (const r of results) {
      expect(r.success).toBe(false);
    }
  });

  test("openExternal/showItemInFolder/beep 인터리브 60회", async () => {
    for (let i = 0; i < 60; i++) {
      const op = i % 3;
      if (op === 0) {
        await core({ cmd: "shell_open_external", url: `bad-${i}` });
      } else if (op === 1) {
        await core({ cmd: "shell_show_item_in_folder", path: `/no/${i}` });
      } else {
        await core({ cmd: "shell_beep" });
      }
    }
  }, 30000);
});

// ============================================
// JSON wire — 백슬래시 / 따옴표 / 유니코드
// ============================================

describe("JSON wire 안전성", () => {
  test("URL에 백슬래시 (RFC상 invalid이지만 crash X)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_external",
      url: "https://example.com/\\path",
    });
    expect(typeof r.success).toBe("boolean");
  });

  test("path에 따옴표 + backslash 혼합 (잘못된 path도 안전)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: 'C:\\Windows\\"System32"\\file',
    });
    expect(r.success).toBe(false);
  });

  test("unicode path는 escape 우회 (잘못된 unicode escape도 안 깨짐)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: "/한글/없는/경로",
    });
    expect(r.success).toBe(false);
  });
});

// ============================================
// 누락 / 잘못된 필드
// ============================================

describe("누락 / 잘못된 필드", () => {
  test("openExternal — url 필드 없음 → empty default → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_external" });
    expect(r.success).toBe(false);
  });

  test("showItemInFolder — path 필드 없음 → empty default → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_show_item_in_folder" });
    expect(r.success).toBe(false);
  });

  test("beep — 인자 무시", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_beep", garbage: 123, extra: "ignored" });
    expect(r.success).toBe(true);
  });
});

// ============================================
// 다중 창 — 다른 창에서 호출도 동작
// ============================================

describe("다중 창", () => {
  test("create_window로 새 창 생성 + (CDP target 잡으면) 새 창에서 shell.beep 동작", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "Shell Test B",
      url: "http://localhost:5173/",
      width: 400,
      height: 300,
    });
    expect(created.windowId).toBeGreaterThan(0);

    // CEF runtime-created browser는 CDP에 자동 노출 안 될 수 있음 — 잡히면 추가 검증.
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
      const r = await newPage.evaluate(async () => {
        const bridge = (window as any).__suji__;
        const resp = await bridge.core(JSON.stringify({ cmd: "shell_beep" }));
        return resp.success;
      });
      expect(r).toBe(true);
    } else {
      // CDP에서 못 잡으면 windowId 유효 검증으로 만족 — 새 창은 OS 레벨에서 떠 있음.
      expect(created.windowId).toBeGreaterThan(0);
    }
  }, 30000);
});
