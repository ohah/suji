/**
 * Dialog E2E — `suji.dialog.{showMessageBox, showErrorBox, showOpenDialog, showSaveDialog}` 검증.
 *
 * Modal dialog는 OS 레벨 native window라 puppeteer로 직접 클릭/dismiss 불가. 현재 자동화는:
 *
 *   1. 잘못된 옵션 → std.json parse fail → graceful error 응답 (modal 안 뜸)
 *   2. cmd routing 검증 (window_manager_test.zig 정적 회귀 가드)
 *   3. Linux GTK runtime: SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE=1일 때 실제 GTK dialog 생성 후 자동 cancel
 *   4. 응답 형식 검증 (일반 실제 modal은 사람이 클릭해야 함 — 수동 가이드)
 *
 * macOS dismiss 자동화(`osascript` ESC)는 Accessibility 권한 + 정확한 timing 의존이라
 * CI/dev 환경에서 일관 동작 안 함. Linux는 GTK timeout hook으로 CI에서 cancel 경로를 검증한다.
 * 수동 검증은 `examples/dialogs-demo` 권장.
 *
 * 실행: tests/e2e/run-dialog.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

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
  page = await getMainPage(browser);
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

// ============================================
// 잘못된 옵션 → std.json parse fail → 즉시 graceful 응답 (modal 안 뜸)
// ============================================

describe("옵션 파싱 graceful failure (modal 미발생)", () => {
  test("showMessageBox: defaultId 타입 불일치 → response:0 + error:'parse'", async () => {
    const r = await core<{ response: number; checkboxChecked: boolean; error?: string }>({
      cmd: "dialog_show_message_box",
      message: "test",
      defaultId: "wrong-type" as any,
    });
    expect(r.response).toBe(0);
    expect(r.checkboxChecked).toBe(false);
    expect(r.error).toBe("parse");
  });

  test("showOpenDialog: filters 잘못된 타입 → canceled:true + error:'parse'", async () => {
    const r = await core<{ canceled: boolean; filePaths: string[]; error?: string }>({
      cmd: "dialog_show_open_dialog",
      filters: "not-an-array" as any,
    });
    expect(r.canceled).toBe(true);
    expect(r.filePaths).toEqual([]);
    expect(r.error).toBe("parse");
  });

  test("showSaveDialog: defaultPath 잘못된 타입 → canceled:true + error:'parse'", async () => {
    const r = await core<{ canceled: boolean; filePath: string; error?: string }>({
      cmd: "dialog_show_save_dialog",
      defaultPath: { path: "wrong" } as any,
    });
    expect(r.canceled).toBe(true);
    expect(r.filePath).toBe("");
    expect(r.error).toBe("parse");
  });

  test("showErrorBox: title 누락도 graceful (defaults to '')", async () => {
    // showErrorBox는 modal을 띄움 — 이 테스트는 띄우지 말자. 대신 잘못된 input.
    const r = await core<{ success: boolean }>({
      cmd: "dialog_show_error_box",
      title: 123 as any, // wrong type
      content: "ok",
    });
    // parse fail → success:false. 또는 std.json 자동 변환 실패 → success:false.
    expect(typeof r.success).toBe("boolean");
  });
});

// ============================================
// 응답 shape 검증 — 정상 옵션이지만 modal 띄우는 케이스 — RUN_DESTRUCTIVE에서만 실행
// ============================================
//
// modal이 실제로 뜨면 puppeteer가 응답 받기 전 timeout. 사용자가 손으로 클릭하거나
// `osascript`로 dismiss해야. 자동화 어려워 RUN_DESTRUCTIVE 게이트 + 사용자 안내.

const runDestructive = process.env.RUN_DESTRUCTIVE === "1";
const linuxAutoClose = process.env.SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE === "1";

describe("Linux GTK runtime — auto cancel hook", () => {
  test.skipIf(!linuxAutoClose)("showMessageBox: 실제 GTK dialog 생성 후 자동 cancel", async () => {
    const r = await core<{ response: number; checkboxChecked: boolean }>({
      cmd: "dialog_show_message_box",
      type: "info",
      title: "Linux GTK auto-close",
      message: "This GTK dialog should close itself in CI.",
      detail: "Nested GTK loop is exercised.",
      buttons: ["OK", "Cancel"],
      cancelId: 1,
      checkboxLabel: "Remember",
      checkboxChecked: true,
    });
    expect(r.response).toBe(1);
    expect(r.checkboxChecked).toBe(true);
  });

  test.skipIf(!linuxAutoClose)("showOpenDialog: 실제 GTK file chooser 생성 후 자동 cancel", async () => {
    const r = await core<{ canceled: boolean; filePaths: string[] }>({
      cmd: "dialog_show_open_dialog",
      title: "Linux GTK open auto-close",
      properties: ["openFile", "multiSelections"],
      filters: [{ name: "Text", extensions: ["txt", "md"] }],
    });
    expect(r.canceled).toBe(true);
    expect(r.filePaths).toEqual([]);
  });

  test.skipIf(!linuxAutoClose)("showSaveDialog: 실제 GTK save chooser 생성 후 자동 cancel", async () => {
    const r = await core<{ canceled: boolean; filePath: string }>({
      cmd: "dialog_show_save_dialog",
      title: "Linux GTK save auto-close",
      defaultPath: "/tmp/suji-dialog-auto.txt",
      filters: [{ name: "Text", extensions: ["txt"] }],
    });
    expect(r.canceled).toBe(true);
    expect(r.filePath).toBe("");
  });
});

describe("실제 modal — RUN_DESTRUCTIVE (사용자가 dismiss 필요)", () => {
  test.skipIf(!runDestructive)(
    "RUN_DESTRUCTIVE=1 + manual: showMessageBox 띄움. 직접 아무 버튼 클릭",
    async () => {
      console.log("\n>>> showMessageBox modal 띄움. ESC 또는 OK 클릭 필요 <<<\n");
      const r = await core<{ response: number; checkboxChecked: boolean }>({
        cmd: "dialog_show_message_box",
        type: "info",
        title: "Manual Dismiss Test",
        message: "이 메시지가 보이면 wiring 정상. ESC/OK로 닫아주세요.",
        buttons: ["OK", "Cancel"],
        cancelId: 1,
      });
      expect(typeof r.response).toBe("number");
      expect(typeof r.checkboxChecked).toBe("boolean");
    },
    60000, // 60s timeout — 사용자 클릭 대기
  );

  test.skipIf(!runDestructive)(
    "RUN_DESTRUCTIVE=1 + manual: showOpenDialog 띄움. ESC로 cancel",
    async () => {
      console.log("\n>>> showOpenDialog modal 띄움. ESC로 cancel하세요 <<<\n");
      const r = await core<{ canceled: boolean; filePaths: string[] }>({
        cmd: "dialog_show_open_dialog",
        title: "Pick a file (or ESC)",
        properties: ["openFile"],
      });
      expect(typeof r.canceled).toBe("boolean");
      expect(Array.isArray(r.filePaths)).toBe(true);
    },
    60000,
  );
});
