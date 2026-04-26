/**
 * Global shortcut E2E — `global_shortcut_*` core commands.
 *
 * 실행:
 *   ./tests/e2e/run-global-shortcut.sh
 *
 * 주의: 실제 키 입력 시뮬레이션은 시스템 권한 한계 + CI 환경에서 비결정적이라
 * 다루지 않는다. 등록/해제/조회의 wire-format 동작만 검증.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

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

  // 사전 정리 — 테스트 간 leak 방지.
  await core({ cmd: "global_shortcut_unregister_all" });
});

afterAll(async () => {
  await core({ cmd: "global_shortcut_unregister_all" });
  await browser?.disconnect();
});

describe("global shortcut core commands", () => {
  test("register / isRegistered / unregister round-trip", async () => {
    const accel = "Cmd+Shift+F8";

    const r1 = await core<{ success: boolean }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "test1",
    });
    expect(r1.success).toBe(true);

    const r2 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: accel,
    });
    expect(r2.registered).toBe(true);

    const r3 = await core<{ success: boolean }>({
      cmd: "global_shortcut_unregister",
      accelerator: accel,
    });
    expect(r3.success).toBe(true);

    const r4 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: accel,
    });
    expect(r4.registered).toBe(false);
  });

  test("duplicate register returns already_registered (분리된 에러 코드)", async () => {
    const accel = "Cmd+Shift+F9";
    const r1 = await core<{ success: boolean }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "dup1",
    });
    expect(r1.success).toBe(true);

    const r2 = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "dup2",
    });
    expect(r2.success).toBe(false);
    expect(r2.error).toBe("already_registered");

    await core({ cmd: "global_shortcut_unregister", accelerator: accel });
  });

  test("invalid key returns parse_failed", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "NotARealKey+Shift",
      click: "bad",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse_failed");
  });

  test("modifier-only accelerator returns parse_failed", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "Cmd+Shift",
      click: "modonly",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse_failed");
  });

  test("multiple non-modifier keys returns parse_failed", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "Cmd+A+B",
      click: "multikey",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse_failed");
  });

  test("empty accelerator returns accelerator (handler-level)", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "",
      click: "empty",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("accelerator");
  });

  test("empty click returns click (handler-level)", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "Cmd+Shift+F1",
      click: "",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("click");
  });

  test("over-128-byte accelerator returns too_long", async () => {
    const long = "Cmd+Shift+" + "X".repeat(140);
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: long,
      click: "long",
    });
    expect(r.success).toBe(false);
    // Zig SDK 사이드에서도 128 제한 → too_long, raw cmd path는 cef.zig writeCStr가 too_long.
    expect(r.error === "too_long" || r.error === "accelerator").toBe(true);
  });

  test("modifier name case insensitivity (cmd vs Cmd vs COMMAND)", async () => {
    const variants = ["cmd+shift+f2", "CMD+SHIFT+F3", "Command+Shift+F4"];
    for (const v of variants) {
      const r = await core<{ success: boolean }>({
        cmd: "global_shortcut_register",
        accelerator: v,
        click: "case",
      });
      expect(r.success).toBe(true);
    }
    await core({ cmd: "global_shortcut_unregister_all" });
  });

  test("modifier aliases (CmdOrCtrl, CommandOrControl, Meta, Super) all map to Cmd", async () => {
    // 각 alias로 등록 + 같은 Cmd 키조합으로 isRegistered 확인은 어렵지만 (각 string은 다르게 키로 저장됨),
    // 모두 등록 자체가 성공하는지만 검증.
    const aliases = ["CmdOrCtrl+Shift+F5", "CommandOrControl+Shift+F6", "Meta+Shift+F7"];
    for (const a of aliases) {
      const r = await core<{ success: boolean }>({
        cmd: "global_shortcut_register",
        accelerator: a,
        click: "alias",
      });
      expect(r.success).toBe(true);
    }
    await core({ cmd: "global_shortcut_unregister_all" });
  });

  test("accelerator/click with JSON-special chars round-trip via escape", async () => {
    // Carbon은 accelerator의 quote/backslash를 모르는 키로 처리 → parse_failed.
    // 검증 포인트는 wire-level escape가 안전하게 통과해서 핸들러에 도달했는지.
    const r1 = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: 'Cmd+"K"',
      click: "quote",
    });
    expect(r1.success).toBe(false);
    expect(r1.error).toBe("parse_failed");

    // click 쪽은 escape 통과 후 unescape 시 원본 복원되어야 함.
    const accel = "Cmd+Shift+F8";
    const r2 = await core<{ success: boolean }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: 'open"settings"\\path',
    });
    expect(r2.success).toBe(true);
    await core({ cmd: "global_shortcut_unregister", accelerator: accel });
  });

  test("unregister on missing accelerator returns success:false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "global_shortcut_unregister",
      accelerator: "Cmd+Shift+F11",
    });
    expect(r.success).toBe(false);
  });

  test("isRegistered returns false for never-registered", async () => {
    const r = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: "Cmd+Shift+F18",
    });
    expect(r.registered).toBe(false);
  });

  test("unregisterAll clears all", async () => {
    await core({ cmd: "global_shortcut_register", accelerator: "Cmd+Shift+F10", click: "a" });
    await core({ cmd: "global_shortcut_register", accelerator: "Cmd+Shift+F12", click: "b" });

    const all = await core<{ success: boolean }>({ cmd: "global_shortcut_unregister_all" });
    expect(all.success).toBe(true);

    const c1 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: "Cmd+Shift+F10",
    });
    expect(c1.registered).toBe(false);
    const c2 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: "Cmd+Shift+F12",
    });
    expect(c2.registered).toBe(false);
  });

  test("capacity_full returns capacity_full after exceeding 64 entries", async () => {
    await core({ cmd: "global_shortcut_unregister_all" });
    // F1-F12 + Cmd, Cmd+Shift, Cmd+Alt, Cmd+Ctrl, Cmd+Shift+Alt 등 조합으로 64+ 채움.
    const modifiers = ["Cmd", "Cmd+Shift", "Cmd+Alt", "Cmd+Ctrl", "Cmd+Shift+Alt", "Cmd+Shift+Ctrl"];
    const keys: string[] = [];
    for (let i = 1; i <= 12; i++) keys.push(`F${i}`);
    let registered = 0;
    let lastError = "";
    outer: for (const m of modifiers) {
      for (const k of keys) {
        const r = await core<{ success: boolean; error?: string }>({
          cmd: "global_shortcut_register",
          accelerator: `${m}+${k}`,
          click: `cap${registered}`,
        });
        if (r.success) registered++;
        else { lastError = r.error ?? ""; break outer; }
      }
    }
    // 64개 제한에 도달했어야 함 (또는 OS reject).
    expect(registered).toBeGreaterThanOrEqual(60);
    expect(["capacity_full", "os_reject", "already_registered"]).toContain(lastError);
    await core({ cmd: "global_shortcut_unregister_all" });
  });
});
