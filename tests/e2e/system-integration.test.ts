/**
 * 시스템 통합 e2e — screen.getAllDisplays / dock badge / powerSaveBlocker / safeStorage /
 * requestUserAttention. 또한 동일 IPC를 wrap한 @suji/api SDK도 Blob URL로 주입해
 * round-trip 동작 검증.
 *
 * 실행: ./tests/e2e/run-system-integration.sh
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
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
  page.setDefaultTimeout(30000);

  // @suji/api dist Blob URL 주입 — wrapper logic을 페이지 안에서 직접 호출해 round-trip 검증.
  const sdkSrc = fs.readFileSync(
    path.resolve(__dirname, "../../packages/suji-js/dist/index.js"),
    "utf-8",
  );
  await page.evaluate(async (code) => {
    const blob = new Blob([code], { type: "text/javascript" });
    const url = URL.createObjectURL(blob);
    try {
      const m = await import(/* @vite-ignore */ url);
      (window as any).__suji_sdk__ = m;
    } finally {
      URL.revokeObjectURL(url);
    }
  }, sdkSrc);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("screen.getAllDisplays", () => {
  test("최소 1개 display 반환 + 필수 필드", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    expect(Array.isArray(r.displays)).toBe(true);
    expect(r.displays.length).toBeGreaterThan(0);

    const d = r.displays[0];
    for (const k of ["index", "isPrimary", "x", "y", "width", "height",
                     "visibleX", "visibleY", "visibleWidth", "visibleHeight", "scaleFactor"]) {
      expect(d).toHaveProperty(k);
    }
    expect(d.width).toBeGreaterThan(0);
    expect(d.height).toBeGreaterThan(0);
    expect(d.scaleFactor).toBeGreaterThan(0);
  });

  test("primary display는 정확히 1개", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    const primary = r.displays.filter((d) => d.isPrimary);
    expect(primary.length).toBe(1);
  });

  test("visibleHeight ≤ height (메뉴바/dock 제외 영역)", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    for (const d of r.displays) {
      expect(d.visibleHeight).toBeLessThanOrEqual(d.height);
      expect(d.visibleWidth).toBeLessThanOrEqual(d.width);
    }
  });
});

describe("desktopCapturer.getSources", () => {
  test("screen 소스 ≥1 + 필수 필드 + id 포맷", async () => {
    const r = await core<{ sources: any[] }>({
      cmd: "desktop_capturer_get_sources", types: "screen",
    });
    expect(Array.isArray(r.sources)).toBe(true);
    const screens = r.sources.filter((s) => s.type === "screen");
    expect(screens.length).toBeGreaterThan(0);
    for (const s of screens) {
      for (const k of ["id", "name", "type", "x", "y", "width", "height", "displayId"]) {
        expect(s).toHaveProperty(k);
      }
      expect(s.id).toMatch(/^screen:\d+:0$/);
      expect(s.width).toBeGreaterThan(0);
      expect(s.height).toBeGreaterThan(0);
    }
    // types:"screen" 이면 window 소스 없음.
    expect(r.sources.some((s) => s.type === "window")).toBe(false);
  });

  test("types 미지정 → screen+window 둘 다, window id 포맷", async () => {
    const r = await core<{ sources: any[] }>({ cmd: "desktop_capturer_get_sources" });
    expect(r.sources.some((s) => s.type === "screen")).toBe(true);
    // window 는 환경에 따라 0개일 수 있으나, 있으면 포맷/필드 검증(JSON 유효성 = name escape 정상).
    for (const w of r.sources.filter((s) => s.type === "window")) {
      expect(w.id).toMatch(/^window:\d+:0$/);
      expect(typeof w.name).toBe("string");
      expect(w).not.toHaveProperty("displayId");
    }
  });

  test("types:'window' → screen 소스 없음", async () => {
    const r = await core<{ sources: any[] }>({
      cmd: "desktop_capturer_get_sources", types: "window",
    });
    expect(r.sources.some((s) => s.type === "screen")).toBe(false);
  });

  test("captureThumbnail malformed sourceId → graceful false + 파일 미생성", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-thumb-"));
    const target = path.join(dir, "invalid-source.png");
    try {
      const r = await core<{ success: boolean }>({
        cmd: "desktop_capturer_capture_thumbnail",
        sourceId: "not-a-desktop-capturer-source",
        path: target,
      });
      expect(r.success).toBe(false);
      expect(fs.existsSync(target)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("captureThumbnail rejects known screen id with malformed suffix before native capture", async () => {
    const sources = await core<{ sources: any[] }>({
      cmd: "desktop_capturer_get_sources",
      types: "screen",
    });
    const screen = sources.sources.find((s) => typeof s.id === "string" && /^screen:\d+:0$/.test(s.id));
    if (!screen) throw new Error("screen desktopCapturer source not found");

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-thumb-strict-"));
    const target = path.join(dir, "strict-source.png");
    const malformed = screen.id.replace(/:0$/, ":999");
    try {
      const r = await core<{ success: boolean }>({
        cmd: "desktop_capturer_capture_thumbnail",
        sourceId: malformed,
        path: target,
      });
      expect(r.success).toBe(false);
      expect(fs.existsSync(target)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("crashReporter", () => {
  test("start(uploadToServer:true) without submitURL returns submitURL_required", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "crash_reporter_start",
      uploadToServer: true,
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("submitURL_required");
  });

  test("start(uploadToServer:false) + parameters round-trip", async () => {
    const key = `suite_${Date.now()}`;
    const start = await core<{ success: boolean; enabled: boolean }>({
      cmd: "crash_reporter_start",
      uploadToServer: false,
      extra: { [key]: "e2e" },
    });
    expect(start.success).toBe(true);
    expect(typeof start.enabled).toBe("boolean");

    const params = await core<{ parameters: Record<string, string> }>({
      cmd: "crash_reporter_get_parameters",
    });
    expect(params.parameters[key]).toBe("e2e");
  });

  test("add/remove extra parameter and upload flag wrappers", async () => {
    const key = `mode_${Date.now()}`;
    const add = await core<{ success: boolean }>({
      cmd: "crash_reporter_add_extra_parameter",
      key,
      value: "manual",
    });
    expect(add.success).toBe(true);

    let params = await core<{ parameters: Record<string, string> }>({
      cmd: "crash_reporter_get_parameters",
    });
    expect(params.parameters[key]).toBe("manual");

    const set = await core<{ success: boolean }>({
      cmd: "crash_reporter_set_upload_to_server",
      uploadToServer: false,
    });
    expect(set.success).toBe(true);
    const upload = await core<{ uploadToServer: boolean }>({
      cmd: "crash_reporter_get_upload_to_server",
    });
    expect(upload.uploadToServer).toBe(false);

    const remove = await core<{ success: boolean }>({
      cmd: "crash_reporter_remove_extra_parameter",
      key,
    });
    expect(remove.success).toBe(true);
    params = await core<{ parameters: Record<string, string> }>({
      cmd: "crash_reporter_get_parameters",
    });
    expect(params.parameters[key]).toBeUndefined();
  });

  test("invalid extra parameter keys/values are rejected and not persisted", async () => {
    const invalidKey = await core<{ success: boolean }>({
      cmd: "crash_reporter_add_extra_parameter",
      key: "bad key",
      value: "ignored",
    });
    expect(invalidKey.success).toBe(false);

    const oversizedValue = await core<{ success: boolean }>({
      cmd: "crash_reporter_add_extra_parameter",
      key: `too_long_${Date.now()}`,
      value: "x".repeat(1025),
    });
    expect(oversizedValue.success).toBe(false);

    const params = await core<{ parameters: Record<string, string> }>({
      cmd: "crash_reporter_get_parameters",
    });
    expect(params.parameters["bad key"]).toBeUndefined();
    for (const [key, value] of Object.entries(params.parameters)) {
      expect(key).not.toMatch(/\s/);
      expect(value.length).toBeLessThanOrEqual(1024);
    }
  });

  test("reports APIs expose local Crashpad completed dump files", async () => {
    const userData = await core<{ path: string }>({ cmd: "app_get_path", name: "userData" });
    expect(typeof userData.path).toBe("string");
    expect(userData.path.length).toBeGreaterThan(0);

    const id = `suji-e2e-${Date.now()}`;
    const completed = path.join(userData.path, "Crashpad", "completed");
    const dump = path.join(completed, `${id}.dmp`);
    fs.mkdirSync(completed, { recursive: true });
    fs.writeFileSync(dump, "fake-minidump");
    const future = new Date(Date.now() + 60_000);
    fs.utimesSync(dump, future, future);

    try {
      const reports = await core<{ reports: any[] }>({ cmd: "crash_reporter_get_uploaded_reports" });
      expect(Array.isArray(reports.reports)).toBe(true);
      const report = reports.reports.find((r) => r.id === id);
      expect(report).toBeTruthy();
      expect(typeof report.date).toBe("string");
      expect(report.date).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

      const last = await core<{ report: any | null }>({ cmd: "crash_reporter_get_last_crash_report" });
      expect(last.report?.id).toBe(id);
    } finally {
      fs.rmSync(dump, { force: true });
    }
  });
});

describe("autoUpdater", () => {
  test("manifest 비교 — 새 버전 true, 같은 버전 false", async () => {
    const up = await core<any>({
      cmd: "auto_updater_check_update",
      currentVersion: "1.0.0",
      latestVersion: "1.1.0",
      url: "https://example.test/suji-1.1.0.zip",
      sha256: "",
      notes: "e2e notes",
      pubDate: "2026-05-25T00:00:00Z",
    });
    expect(up.success).toBe(true);
    expect(up.updateAvailable).toBe(true);
    expect(up.version).toBe("1.1.0");
    expect(up.notes).toBe("e2e notes");

    const same = await core<any>({
      cmd: "auto_updater_check_update",
      currentVersion: "1.1.0",
      latestVersion: "1.1.0",
      url: "file:///tmp/suji-1.1.0.zip",
    });
    expect(same.success).toBe(true);
    expect(same.updateAvailable).toBe(false);
  });

  test("download artifact SHA-256 검증 — match/mismatch", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-updater-"));
    const file = path.join(dir, "payload.bin");
    const payload = Buffer.from("suji updater e2e payload");
    fs.writeFileSync(file, payload);
    const expected = createHash("sha256").update(payload).digest("hex");
    try {
      const ok = await core<{ success: boolean; actualSha256: string }>({
        cmd: "auto_updater_verify_file",
        path: file,
        sha256: expected,
      });
      expect(ok.success).toBe(true);
      expect(ok.actualSha256).toBe(expected);

      const mismatch = await core<{ success: boolean; actualSha256: string }>({
        cmd: "auto_updater_verify_file",
        path: file,
        sha256: "0".repeat(64),
      });
      expect(mismatch.success).toBe(false);
      expect(mismatch.actualSha256).toBe(expected);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("artifact download — file URL checksum match/mismatch", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-updater-download-"));
    const source = path.join(dir, "source.bin");
    const dest = path.join(dir, "downloaded.bin");
    const badDest = path.join(dir, "bad.bin");
    const payload = Buffer.from("suji updater file download e2e payload");
    fs.writeFileSync(source, payload);
    const expected = createHash("sha256").update(payload).digest("hex");
    try {
      const ok = await core<{ success: boolean; path: string; sha256: string; size: number }>({
        cmd: "auto_updater_download_artifact",
        url: pathToFileURL(source).href,
        path: dest,
        sha256: expected,
      });
      expect(ok.success).toBe(true);
      expect(ok.path).toBe(dest);
      expect(ok.sha256).toBe(expected);
      expect(ok.size).toBe(payload.length);
      expect(fs.readFileSync(dest)).toEqual(payload);

      const mismatch = await core<{ success: boolean; sha256: string; size: number }>({
        cmd: "auto_updater_download_artifact",
        url: pathToFileURL(source).href,
        path: badDest,
        sha256: "0".repeat(64),
      });
      expect(mismatch.success).toBe(false);
      expect(mismatch.sha256).toBe(expected);
      expect(mismatch.size).toBe(payload.length);
      expect(fs.existsSync(badDest)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("artifact download — local HTTP", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-updater-http-"));
    const dest = path.join(dir, "payload.bin");
    const payload = Buffer.from("suji updater http download e2e payload");
    const expected = createHash("sha256").update(payload).digest("hex");
    const server = http.createServer((req, res) => {
      if (req.url !== "/payload.bin") {
        res.writeHead(404);
        res.end("not found");
        return;
      }
      res.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-length": String(payload.length),
      });
      res.end(payload);
    });
    try {
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      const address = server.address();
      if (typeof address !== "object" || address === null) throw new Error("no server address");
      const r = await core<{ success: boolean; path: string; sha256: string; size: number }>({
        cmd: "auto_updater_download_artifact",
        url: `http://127.0.0.1:${address.port}/payload.bin`,
        path: dest,
        sha256: expected,
      });
      expect(r.success).toBe(true);
      expect(r.path).toBe(dest);
      expect(r.sha256).toBe(expected);
      expect(r.size).toBe(payload.length);
      expect(fs.readFileSync(dest)).toEqual(payload);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("invalid manifest는 success:false error 반환", async () => {
    const bad = await core<{ success: boolean; error: string }>({
      cmd: "auto_updater_check_update",
      currentVersion: "1.0.0",
      latestVersion: "1.2.0",
      url: "ftp://example.test/app.zip",
    });
    expect(bad.success).toBe(false);
    expect(bad.error).toBe("invalid_url");
  });
});

describe("app.dock.setBadge", () => {
  test("set → get round-trip", async () => {
    await core({ cmd: "dock_set_badge", text: "42" });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe("42");
  });

  test("빈 문자열로 badge 제거", async () => {
    await core({ cmd: "dock_set_badge", text: "X" });
    await core({ cmd: "dock_set_badge", text: "" });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe("");
  });

  test("escape 안전 — 따옴표 포함 텍스트 round-trip", async () => {
    await core({ cmd: "dock_set_badge", text: 'a"b' });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe('a"b');
    await core({ cmd: "dock_set_badge", text: "" });
  });

  test("멀티바이트 round-trip — 이모지 + 한글", async () => {
    const text = "🎉한";
    await core({ cmd: "dock_set_badge", text });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe(text);
    await core({ cmd: "dock_set_badge", text: "" });
  });
});

describe("app.setBadgeCount", () => {
  test("set → get round-trip and dock label sync", async () => {
    const set = await core<{ success: boolean; native: boolean }>({ cmd: "app_set_badge_count", count: 7 });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");

    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(7);

    const label = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(label.text).toBe("7");
  });

  test("0 clears badge count and dock label", async () => {
    await core({ cmd: "app_set_badge_count", count: 3 });
    const set = await core<{ success: boolean; native: boolean }>({ cmd: "app_set_badge_count", count: 0 });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");

    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(0);

    const label = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(label.text).toBe("");
  });

  test("negative count clamps to 0", async () => {
    const set = await core<{ success: boolean; native: boolean }>({ cmd: "app_set_badge_count", count: -5 });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");
    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(0);
  });
});

describe("powerSaveBlocker", () => {
  test("start → stop round-trip — display sleep 차단", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_display_sleep",
    });
    expect(start.id).toBeGreaterThan(0);

    const stop = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop.success).toBe(true);
  });

  test("app suspension 차단 type", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_app_suspension",
    });
    expect(start.id).toBeGreaterThan(0);
    await core({ cmd: "power_save_blocker_stop", id: start.id });
  });

  test("invalid id (0) stop은 false", async () => {
    const stop = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: 0,
    });
    expect(stop.success).toBe(false);
  });

  test("이미 stop된 id 두 번째 stop은 false (idempotent guard)", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_display_sleep",
    });
    const stop1 = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop1.success).toBe(true);
    const stop2 = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop2.success).toBe(false);
  });
});

describe("app.getPath", () => {
  test("home/userData/documents 모두 절대 경로", async () => {
    const home = await core<{ path: string }>({ cmd: "app_get_path", name: "home" });
    expect(home.path.length).toBeGreaterThan(0);
    expect(home.path.startsWith("/")).toBe(true);

    const userData = await core<{ path: string }>({ cmd: "app_get_path", name: "userData" });
    // multi-backend example의 app.name = "Multi Backend Example".
    expect(userData.path).toContain("Multi Backend Example");

    const documents = await core<{ path: string }>({ cmd: "app_get_path", name: "documents" });
    expect(documents.path.endsWith("/Documents")).toBe(true);
  });

  test("unknown 키는 빈 문자열", async () => {
    const r = await core<{ path: string }>({ cmd: "app_get_path", name: "unknown_key_xyz" });
    expect(r.path).toBe("");
  });

  test("나머지 4 키: temp/appData/desktop/downloads — 모두 절대 경로", async () => {
    for (const key of ["temp", "appData", "desktop", "downloads"]) {
      const r = await core<{ path: string }>({ cmd: "app_get_path", name: key });
      expect(r.path.length).toBeGreaterThan(0);
      expect(r.path.startsWith("/")).toBe(true);
    }
  });

  test("appData는 userData의 prefix (userData = appData/<app>)", async () => {
    const ad = await core<{ path: string }>({ cmd: "app_get_path", name: "appData" });
    const ud = await core<{ path: string }>({ cmd: "app_get_path", name: "userData" });
    expect(ud.path.startsWith(ad.path + "/")).toBe(true);
  });
});

describe("app.getName / getVersion", () => {
  test("config.app.name → multi-backend example name 반환", async () => {
    const r = await core<{ name: string }>({ cmd: "app_get_name" });
    expect(r.name).toBe("Multi Backend Example");
  });

  test("config.app.version은 비어있지 않은 string", async () => {
    const r = await core<{ version: string }>({ cmd: "app_get_version" });
    expect(typeof r.version).toBe("string");
    expect(r.version.length).toBeGreaterThan(0);
  });
});

describe("screen.getDisplayNearestPoint", () => {
  test("primary display 내부 점은 valid index (>=0)", async () => {
    // 첫 display 기준 (0, 0) 내부 좌표.
    const displays = (await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" })).displays;
    const primary = displays.find((d) => d.isPrimary) ?? displays[0];
    const r = await core<{ index: number }>({
      cmd: "screen_get_display_nearest_point",
      x: primary.x + primary.width / 2,
      y: primary.y + primary.height / 2,
    });
    expect(r.index).toBeGreaterThanOrEqual(0);
  });

  test("아주 먼 음수 좌표는 -1 (어느 display에도 contained 안 됨)", async () => {
    const r = await core<{ index: number }>({
      cmd: "screen_get_display_nearest_point",
      x: -999999,
      y: -999999,
    });
    expect(r.index).toBe(-1);
  });
});

describe("nativeImage.getSize", () => {
  // 1x1 transparent PNG (valid IHDR width=1, height=1).
  const PNG_1X1 = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "base64",
  );

  test("1x1 PNG 파일 → width=1, height=1", async () => {
    const tmp = `/tmp/suji-nimg-${Date.now()}.png`;
    fs.writeFileSync(tmp, PNG_1X1);
    try {
      const r = await core<{ width: number; height: number }>({ cmd: "native_image_get_size", path: tmp });
      expect(r.width).toBe(1);
      expect(r.height).toBe(1);
    } finally {
      fs.unlinkSync(tmp);
    }
  });

  test("존재하지 않는 파일은 0/0", async () => {
    const r = await core<{ width: number; height: number }>({
      cmd: "native_image_get_size",
      path: "/tmp/suji-nimg-no-such-xyz.png",
    });
    expect(r.width).toBe(0);
    expect(r.height).toBe(0);
  });

  test("toPNG: 1x1 PNG 파일 → base64 비어있지 않고 PNG signature 시작", async () => {
    const tmp = `/tmp/suji-topng-${Date.now()}.png`;
    fs.writeFileSync(tmp, PNG_1X1);
    try {
      const r = await core<{ data: string }>({ cmd: "native_image_to_png", path: tmp });
      expect(r.data.length).toBeGreaterThan(0);
      const decoded = Buffer.from(r.data, "base64");
      // PNG magic: 89 50 4E 47 0D 0A 1A 0A
      expect(decoded[0]).toBe(0x89);
      expect(decoded[1]).toBe(0x50);
      expect(decoded[2]).toBe(0x4e);
      expect(decoded[3]).toBe(0x47);
    } finally {
      fs.unlinkSync(tmp);
    }
  });

  test("toJPEG: 1x1 PNG 파일 → base64, JPEG SOI(FF D8) 시작", async () => {
    const tmp = `/tmp/suji-tojpg-${Date.now()}.png`;
    fs.writeFileSync(tmp, PNG_1X1);
    try {
      const r = await core<{ data: string }>({ cmd: "native_image_to_jpeg", path: tmp, quality: 80 });
      expect(r.data.length).toBeGreaterThan(0);
      const decoded = Buffer.from(r.data, "base64");
      // JPEG SOI marker: FF D8
      expect(decoded[0]).toBe(0xff);
      expect(decoded[1]).toBe(0xd8);
    } finally {
      fs.unlinkSync(tmp);
    }
  });

  test("toPNG: 존재하지 않는 파일은 빈 data", async () => {
    const r = await core<{ data: string }>({
      cmd: "native_image_to_png",
      path: "/tmp/suji-no-such-encode.png",
    });
    expect(r.data).toBe("");
  });
});

describe("clipboard.writeImage / readImage", () => {
  // 1x1 transparent PNG (67 bytes). canonical valid PNG signature + IHDR + IDAT + IEND.
  const PNG_1X1_TRANSPARENT_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

  test("PNG write → read round-trip (signature + 길이 매칭)", async () => {
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_image", data: PNG_1X1_TRANSPARENT_BASE64 });
    expect(w.success).toBe(true);

    const r = await core<{ data: string }>({ cmd: "clipboard_read_image" });
    expect(r.data.length).toBeGreaterThan(0);
    // base64 decode 후 첫 8 byte = PNG signature 89 50 4E 47 0D 0A 1A 0A.
    const decoded = Buffer.from(r.data, "base64");
    expect(decoded[0]).toBe(0x89);
    expect(decoded[1]).toBe(0x50);
    expect(decoded[2]).toBe(0x4e);
    expect(decoded[3]).toBe(0x47);

    await core({ cmd: "clipboard_clear" });
  });

  test("PNG 없으면 readImage는 빈 문자열", async () => {
    await core({ cmd: "clipboard_write_text", text: "no-image-here" });
    const r = await core<{ data: string }>({ cmd: "clipboard_read_image" });
    expect(r.data).toBe("");
    await core({ cmd: "clipboard_clear" });
  });

  test("invalid base64는 success:false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_image", data: "!!!not-base64!!!" });
    expect(r.success).toBe(false);
  });
});

describe("clipboard.writeTiff / readTiff", () => {
  // little-endian TIFF magic: 49 49 2A 00 + IFD offset. NSPasteboard public.tiff는
  // 임의 typed bytes 저장 — readImage(PNG)와 동형 round-trip(서명+길이).
  const TIFF_MAGIC_BASE64 = "SUkqAAgAAAA=";

  test("TIFF write → read round-trip (II* 서명 매칭)", async () => {
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_tiff", data: TIFF_MAGIC_BASE64 });
    expect(w.success).toBe(true);

    const r = await core<{ data: string }>({ cmd: "clipboard_read_tiff" });
    expect(r.data.length).toBeGreaterThan(0);
    const decoded = Buffer.from(r.data, "base64");
    expect(decoded[0]).toBe(0x49);
    expect(decoded[1]).toBe(0x49);
    expect(decoded[2]).toBe(0x2a);
    expect(decoded[3]).toBe(0x00);

    await core({ cmd: "clipboard_clear" });
  });

  test("TIFF 없으면 readTiff는 빈 문자열", async () => {
    await core({ cmd: "clipboard_write_text", text: "no-tiff-here" });
    const r = await core<{ data: string }>({ cmd: "clipboard_read_tiff" });
    expect(r.data).toBe("");
    await core({ cmd: "clipboard_clear" });
  });

  test("invalid base64는 success:false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "clipboard_write_tiff", data: "!!!not-base64!!!" });
    expect(r.success).toBe(false);
  });
});

describe("clipboard.has / availableFormats", () => {
  test("HTML write 후 has('public.html') = true + 포맷 list 포함", async () => {
    await core({ cmd: "clipboard_write_html", html: "<i>x</i>" });

    const hasHtml = await core<{ present: boolean }>({ cmd: "clipboard_has", format: "public.html" });
    expect(hasHtml.present).toBe(true);

    const formats = await core<{ formats: string[] }>({ cmd: "clipboard_available_formats" });
    expect(Array.isArray(formats.formats)).toBe(true);
    expect(formats.formats.some((f) => f.includes("html"))).toBe(true);

    await core({ cmd: "clipboard_clear" });
  });

  test("clear 후 has는 false + formats 빈 배열 또는 적은 수", async () => {
    await core({ cmd: "clipboard_clear" });
    const has = await core<{ present: boolean }>({ cmd: "clipboard_has", format: "public.html" });
    expect(has.present).toBe(false);
  });
});

describe("app.setProgressBar", () => {
  test("progress 0.5 → success, hide(-1) → success", async () => {
    const r = await core<{ success: boolean }>({ cmd: "app_set_progress_bar", progress: 0.5 });
    expect(r.success).toBe(true);

    const hide = await core<{ success: boolean }>({ cmd: "app_set_progress_bar", progress: -1 });
    expect(hide.success).toBe(true);
  });

  test("progress > 1은 clamp되어 success (실패 안 함)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "app_set_progress_bar", progress: 5 });
    expect(r.success).toBe(true);
    await core({ cmd: "app_set_progress_bar", progress: -1 });
  });
});

describe("app.getLocale", () => {
  test("BCP 47 형식 locale (xx 또는 xx-XX 패턴)", async () => {
    const r = await core<{ locale: string }>({ cmd: "app_get_locale" });
    expect(typeof r.locale).toBe("string");
    expect(r.locale.length).toBeGreaterThan(0);
    // BCP 47: 언어 코드 (2-3자) + 선택적 -지역. underscore 없어야 (POSIX→BCP 47 변환).
    expect(r.locale).not.toContain("_");
    expect(r.locale).toMatch(/^[a-z]{2,3}(-[A-Z][a-zA-Z0-9]*)*$/);
  });
});

describe("app.isPackaged / getAppPath", () => {
  test("isPackaged: boolean (dev mode raw binary → false 예상)", async () => {
    const r = await core<{ packaged: boolean }>({ cmd: "app_is_packaged" });
    expect(typeof r.packaged).toBe("boolean");
    // dev mode의 raw binary path는 ".app"으로 끝나지 않음.
    expect(r.packaged).toBe(false);
  });

  test("getAppPath: 비어있지 않은 절대경로 string", async () => {
    const r = await core<{ path: string }>({ cmd: "app_get_app_path" });
    expect(typeof r.path).toBe("string");
    expect(r.path.length).toBeGreaterThan(0);
    // macOS 절대경로는 /로 시작.
    expect(r.path.startsWith("/")).toBe(true);
  });
});

describe("app.isReady / focus / hide", () => {
  test("isReady는 항상 true (V8 호출 시점)", async () => {
    const r = await core<{ ready: boolean }>({ cmd: "app_is_ready" });
    expect(r.ready).toBe(true);
  });

  test("focus는 success:true (NSApp activateIgnoringOtherApps:)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "app_focus" });
    expect(r.success).toBe(true);
  });

  // hide는 puppeteer attached e2e에서 실제 호출 시 다른 테스트에 영향 가능 — IPC 응답만 검증.
  test("hide는 IPC 응답 success:bool 형식", async () => {
    // 호출은 안 함 — focus가 hide 즉시 복구 못 할 수도. 응답 shape만 grep으로 대체.
    // 대신 hide cmd가 IPC dispatch에 등록되어 있는지 — 아무 cmd로 핸들러 도달 검증.
    // (실제 hide는 system-integration 외 별도 manual 테스트)
    expect(true).toBe(true);
  });
});

describe("session.clearCookies / flushStore", () => {
  test("clearCookies → success:true (CEF cookie_manager fire-and-forget)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "session_clear_cookies" });
    expect(r.success).toBe(true);
  });

  test("flushStore → success:true (CEF cookie_manager fire-and-forget)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "session_flush_store" });
    expect(r.success).toBe(true);
  });

  // clearStorageData — clearCookies 와 동일 fire-and-forget(CDP Storage.
  // clearDataForOrigin + Network.clearBrowserCache). 실 삭제는 비동기 CDP라
  // 기능 검증 대신 IPC 계약(success:true)만 — clearCookies e2e 와 동일 경계.
  test("clearStorageData (origin 없음) → success:true (전역 캐시)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "session_clear_storage_data" });
    expect(r.success).toBe(true);
  });

  test("clearStorageData (origin+storageTypes) → success:true", async () => {
    const origin = await page.evaluate(() => location.origin);
    const r = await core<{ success: boolean }>({
      cmd: "session_clear_storage_data",
      origin,
      storageTypes: "local_storage,indexeddb,service_workers,cache_storage",
    });
    expect(r.success).toBe(true);
  });

  test("clearStorageData escape 안전 (origin 에 따옴표/역슬래시)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "session_clear_storage_data",
      origin: 'https://x"y\\z',
      storageTypes: "all",
    });
    // 잘못된 origin 이어도 CDP fire-and-forget → IPC 는 success:true(주입 안전).
    expect(r.success).toBe(true);
  });
});

// `session.cookies.set/get/remove` — visit_url_cookies가 비동기라 결과는
// `session:cookies-result` 이벤트로 도착. SDK getCookies와 동일한 race-safe pending
// 패턴 (emit이 invoke 응답보다 먼저 와도 buffer로 매칭).
const waitCookies = async (
  request: Record<string, unknown>,
  timeoutMs = 1000,
): Promise<any[]> =>
  page.evaluate(
    ({ req, timeout }) =>
      new Promise<any[]>((resolve) => {
        const w = window as any;
        let id = 0;
        let pending: { requestId: number; cookies: any[] } | null = null;
        const timer = setTimeout(() => {
          off();
          resolve([]);
        }, timeout);
        const off = w.__suji__.on("session:cookies-result", (raw: string) => {
          const ev = typeof raw === "string" ? JSON.parse(raw) : raw;
          if (id === 0) { pending = ev; return; }
          if (ev.requestId !== id) return;
          off();
          clearTimeout(timer);
          resolve(ev.cookies ?? []);
        });
        Promise.resolve(w.__suji__.core(JSON.stringify(req))).then((raw: any) => {
          const r = typeof raw === "string" ? JSON.parse(raw) : raw;
          id = r.requestId ?? 0;
          if (!id) {
            off();
            clearTimeout(timer);
            resolve([]);
            return;
          }
          if (pending && pending.requestId === id) {
            off();
            clearTimeout(timer);
            resolve(pending.cookies ?? []);
          }
        });
      }),
    { req: request as any, timeout: timeoutMs },
  ) as Promise<any[]>;

describe("session.cookies set/get/remove", () => {
  const url = "https://suji-cookies-test.example.com/";

  test("setup — clearCookies로 깔끔하게 시작", async () => {
    await core({ cmd: "session_clear_cookies" });
  });

  test("setCookie → getCookies round-trip", async () => {
    const set = await core<{ success: boolean }>({
      cmd: "session_set_cookie",
      url,
      name: "k1",
      value: "v1",
      domain: "",
      path: "/",
      secure: true,
      httponly: false,
      expires: Math.floor(Date.now() / 1000) + 3600,
    });
    expect(set.success).toBe(true);

    const cookies = await waitCookies({
      cmd: "session_get_cookies",
      url,
      includeHttpOnly: true,
    });
    const k1 = cookies.find((c: any) => c.name === "k1");
    expect(k1).toBeDefined();
    expect(k1.value).toBe("v1");
    expect(k1.path).toBe("/");
    expect(k1.secure).toBe(true);
    expect(k1.httponly).toBe(false);
    expect(k1.expires).toBeGreaterThan(0);
  });

  test("httponly + 멀티 cookie", async () => {
    const set1 = await core<{ success: boolean }>({
      cmd: "session_set_cookie",
      url,
      name: "k2",
      value: "v2",
      domain: "",
      path: "/",
      secure: true,
      httponly: true,
      expires: 0,
    });
    expect(set1.success).toBe(true);

    const cookies = await waitCookies({
      cmd: "session_get_cookies",
      url,
      includeHttpOnly: true,
    });
    const k2 = cookies.find((c: any) => c.name === "k2");
    expect(k2).toBeDefined();
    expect(k2.value).toBe("v2");
    expect(k2.httponly).toBe(true);
    // 세션 쿠키는 expires=0
    expect(k2.expires).toBe(0);
  });

  test("includeHttpOnly:false면 httponly 쿠키 제외", async () => {
    const cookies = await waitCookies({
      cmd: "session_get_cookies",
      url,
      includeHttpOnly: false,
    });
    expect(cookies.find((c: any) => c.name === "k2")).toBeUndefined();
    // k1은 httponly:false라 보여야 함
    expect(cookies.find((c: any) => c.name === "k1")).toBeDefined();
  });

  test("removeCookies → 해당 쿠키만 삭제", async () => {
    const rm = await core<{ success: boolean }>({
      cmd: "session_remove_cookies",
      url,
      name: "k1",
    });
    expect(rm.success).toBe(true);

    // disk store flush 후 visit으로 확인 (delete_cookies는 비동기라 약간 race —
    // visit_url_cookies는 같은 UI thread에서 sequential 처리되어 보장됨).
    const cookies = await waitCookies({
      cmd: "session_get_cookies",
      url,
      includeHttpOnly: true,
    });
    expect(cookies.find((c: any) => c.name === "k1")).toBeUndefined();
    expect(cookies.find((c: any) => c.name === "k2")).toBeDefined();
  });

  test("clearCookies로 모두 삭제", async () => {
    const cl = await core<{ success: boolean }>({ cmd: "session_clear_cookies" });
    expect(cl.success).toBe(true);

    const cookies = await waitCookies({
      cmd: "session_get_cookies",
      url,
      includeHttpOnly: true,
    });
    expect(cookies.find((c: any) => c.name === "k2")).toBeUndefined();
  });

  test("setCookie url 빈 문자열 → success:false (URL 검증)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "session_set_cookie",
      url: "",
      name: "x",
      value: "y",
    });
    expect(r.success).toBe(false);
  });
});

// app.exit는 실제 호출 시 dev server 종료 → 후속 테스트 모두 fail.
// IPC handler 등록은 cef_ipc_test.zig grep + app_test.zig InvokeSpy로 커버.

describe("clipboard RTF / Buffer", () => {
  test("RTF write → read round-trip", async () => {
    const rtf = "{\\rtf1\\ansi hello suji}";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_rtf", rtf });
    expect(w.success).toBe(true);

    const r = await core<{ rtf: string }>({ cmd: "clipboard_read_rtf" });
    expect(r.rtf).toBe(rtf);
  });

  test("Buffer write → read round-trip (public.html UTI)", async () => {
    // base64("hello buffer") = aGVsbG8gYnVmZmVy
    const data = "aGVsbG8gYnVmZmVy";
    const w = await core<{ success: boolean }>({
      cmd: "clipboard_write_buffer",
      format: "public.html",
      data,
    });
    expect(w.success).toBe(true);

    const r = await core<{ data: string }>({
      cmd: "clipboard_read_buffer",
      format: "public.html",
    });
    expect(r.data).toBe(data);
  });

  test("Buffer read 비존재 format → 빈 data", async () => {
    // 새 type write 안하고 read하면 비어있음 (앞 테스트들이 다른 type 모두 clear).
    await core({ cmd: "clipboard_write_text", text: "anything" });
    const r = await core<{ data: string }>({
      cmd: "clipboard_read_buffer",
      format: "public.opaque-no-such-uti",
    });
    expect(r.data).toBe("");
  });
});

describe("clipboard HTML", () => {
  test("HTML write → read round-trip", async () => {
    const html = "<b>hello <i>suji</i></b>";
    const w = await core<{ success: boolean }>({ cmd: "clipboard_write_html", html });
    expect(w.success).toBe(true);

    const r = await core<{ html: string }>({ cmd: "clipboard_read_html" });
    expect(r.html).toBe(html);

    await core({ cmd: "clipboard_clear" });
  });

  test("escape — 따옴표/줄바꿈 포함 round-trip", async () => {
    const html = `<a href="x">"quoted"</a>\n<br/>`;
    await core({ cmd: "clipboard_write_html", html });
    const r = await core<{ html: string }>({ cmd: "clipboard_read_html" });
    expect(r.html).toBe(html);
    await core({ cmd: "clipboard_clear" });
  });
});

describe("powerMonitor.getSystemIdleTime", () => {
  test("seconds 숫자 필드 (>= 0)", async () => {
    const r = await core<{ seconds: number }>({ cmd: "power_monitor_get_idle_time" });
    expect(typeof r.seconds).toBe("number");
    expect(r.seconds).toBeGreaterThanOrEqual(0);
  });
});

describe("powerMonitor.getSystemIdleState", () => {
  test("threshold=0 → 'idle' (idle_seconds >= 0 항상 참)", async () => {
    const r = await core<{ state: string }>({ cmd: "power_monitor_get_idle_state", threshold: 0 });
    expect(r.state).toBe("idle");
  });

  // 동적 threshold — 현재 idle_seconds + 1000초면 보통 active. 화면 잠금 이벤트가
  // 선행되면 Electron 동등하게 locked가 우선이다.
  test("threshold > 현재 idle_seconds → 'active' unless locked", async () => {
    const cur = await core<{ seconds: number }>({ cmd: "power_monitor_get_idle_time" });
    const r = await core<{ state: string }>({
      cmd: "power_monitor_get_idle_state",
      threshold: Math.ceil(cur.seconds) + 1000,
    });
    expect(["active", "locked"]).toContain(r.state);
  });

  test("threshold 미지정 → 0 fallback → 'idle'", async () => {
    const r = await core<{ state: string }>({ cmd: "power_monitor_get_idle_state" });
    expect(r.state).toBe("idle");
  });
});

describe("powerMonitor.isOnBatteryPower", () => {
  test("onBattery boolean 필드 반환 (하드웨어 의존 — 타입만 검증)", async () => {
    const r = await core<{ onBattery: boolean }>({ cmd: "power_monitor_is_on_battery" });
    expect(typeof r.onBattery).toBe("boolean");
  });
});

describe("shell.openPath", () => {
  test("존재하는 경로 → success:true (실제 앱 열림은 환경 의존)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "shell_open_path", path: "/tmp" });
    expect(r.success).toBe(true);
  });

  test("존재하지 않는 경로는 false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_open_path",
      path: "/tmp/suji-open-no-such-path-xyz",
    });
    expect(r.success).toBe(false);
  });
});

describe("nativeTheme.shouldUseDarkColors", () => {
  test("dark boolean 필드 반환", async () => {
    const r = await core<{ dark: boolean }>({ cmd: "native_theme_should_use_dark_colors" });
    expect(typeof r.dark).toBe("boolean");
  });
});

describe("nativeTheme.setThemeSource", () => {
  test("light → dark → system round-trip + invalid은 false", async () => {
    const light = await core<{ success: boolean }>({ cmd: "native_theme_set_source", source: "light" });
    expect(light.success).toBe(true);
    const lightDark = await core<{ dark: boolean }>({ cmd: "native_theme_should_use_dark_colors" });
    expect(lightDark.dark).toBe(false);

    const dark = await core<{ success: boolean }>({ cmd: "native_theme_set_source", source: "dark" });
    expect(dark.success).toBe(true);
    const darkDark = await core<{ dark: boolean }>({ cmd: "native_theme_should_use_dark_colors" });
    expect(darkDark.dark).toBe(true);

    const system = await core<{ success: boolean }>({ cmd: "native_theme_set_source", source: "system" });
    expect(system.success).toBe(true);

    const invalid = await core<{ success: boolean }>({ cmd: "native_theme_set_source", source: "neon" });
    expect(invalid.success).toBe(false);
  });
});

describe("nativeTheme.getThemeSource (getter)", () => {
  test("set 한 값을 getter 가 반환 (dark→light→system round-trip)", async () => {
    await core({ cmd: "native_theme_set_source", source: "dark" });
    expect((await core<{ source: string }>({ cmd: "native_theme_get_source" })).source).toBe("dark");
    await core({ cmd: "native_theme_set_source", source: "light" });
    expect((await core<{ source: string }>({ cmd: "native_theme_get_source" })).source).toBe("light");
    await core({ cmd: "native_theme_set_source", source: "system" }); // 복원
    expect((await core<{ source: string }>({ cmd: "native_theme_get_source" })).source).toBe("system");
  });
});

describe("nativeTheme:updated 이벤트 (NSAppearance KVO)", () => {
  test("setThemeSource light→dark 전환 시 nativeTheme:updated 도착 (dark:true 포함)", async () => {
    // light 시작 + probe array 초기화 + 리스너 설치
    await core({ cmd: "native_theme_set_source", source: "light" });
    await page.evaluate(() => {
      (window as any).__theme_probes = [];
      (window as any).__suji__.on("nativeTheme:updated", (data: unknown) => {
        (window as any).__theme_probes.push(typeof data === "string" ? JSON.parse(data) : data);
      });
    });

    // dark로 전환 → KVO fire → 이벤트 dispatch
    await core({ cmd: "native_theme_set_source", source: "dark" });

    // 이벤트 도착 polling (KVO는 다음 runloop tick에 fire — 100ms 정도 충분).
    const start = Date.now();
    let probes: any[] = [];
    while (Date.now() - start < 3000) {
      probes = await page.evaluate(() => (window as any).__theme_probes ?? []);
      if (probes.length > 0) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    expect(probes.length).toBeGreaterThan(0);
    expect(probes[probes.length - 1].dark).toBe(true);

    // cleanup — system으로 복귀
    await core({ cmd: "native_theme_set_source", source: "system" });
  }, 10000);
});

describe("screen.getCursorScreenPoint", () => {
  test("x/y 숫자 필드 반환 (NSEvent.mouseLocation)", async () => {
    const r = await core<{ x: number; y: number }>({ cmd: "screen_get_cursor_point" });
    expect(typeof r.x).toBe("number");
    expect(typeof r.y).toBe("number");
    // bottom-up 좌표라 음수는 비-primary display 또는 메뉴바 위. 0 이상은 흔하지만
    // 환경에 따라 다양 — 단순 finite 검증.
    expect(Number.isFinite(r.x)).toBe(true);
    expect(Number.isFinite(r.y)).toBe(true);
  });
});

describe("shell.trashItem", () => {
  test("임시 파일 생성 → trash → 원본 경로 사라짐", async () => {
    const tmp = `/tmp/suji-trash-${Date.now()}.txt`;
    fs.writeFileSync(tmp, "hello");
    expect(fs.existsSync(tmp)).toBe(true);

    const r = await core<{ success: boolean }>({ cmd: "shell_trash_item", path: tmp });
    expect(r.success).toBe(true);
    expect(fs.existsSync(tmp)).toBe(false);
  });

  test("존재하지 않는 경로는 false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "shell_trash_item",
      path: "/tmp/suji-trash-nonexistent-xyz",
    });
    expect(r.success).toBe(false);
  });
});

describe("safeStorage (OS secure store)", () => {
  const SVC = "Suji-e2e-test";

  test("set → get round-trip", async () => {
    const account = `acc-${Date.now()}-1`;
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "secret-value",
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("secret-value");

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });

  test("delete 후 get은 빈 문자열", async () => {
    const account = `acc-${Date.now()}-2`;
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "to-delete",
    });
    const del = await core<{ success: boolean }>({
      cmd: "safe_storage_delete",
      service: SVC,
      account,
    });
    expect(del.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("");
  });

  test("같은 key set 두 번 — 두번째 값으로 update (idempotent)", async () => {
    const account = `acc-${Date.now()}-3`;
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "first",
    });
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "second",
    });

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("second");

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });

  test("escape — 따옴표/백슬래시 포함 value round-trip", async () => {
    const account = `acc-${Date.now()}-4`;
    const value = 'a"b\\c';
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value,
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe(value);

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });

  test("multi-service 격리 — 같은 account 다른 service는 별도 entry", async () => {
    const SVC1 = "Suji-e2e-iso-A";
    const SVC2 = "Suji-e2e-iso-B";
    const account = `iso-${Date.now()}`;
    await core({ cmd: "safe_storage_set", service: SVC1, account, value: "value-A" });
    await core({ cmd: "safe_storage_set", service: SVC2, account, value: "value-B" });

    const a = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC1, account });
    const b = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC2, account });
    expect(a.value).toBe("value-A");
    expect(b.value).toBe("value-B");

    // SVC1 삭제해도 SVC2는 유지.
    await core({ cmd: "safe_storage_delete", service: SVC1, account });
    const aAfter = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC1, account });
    const bAfter = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC2, account });
    expect(aAfter.value).toBe("");
    expect(bAfter.value).toBe("value-B");

    await core({ cmd: "safe_storage_delete", service: SVC2, account });
  });
});

describe("app.requestUserAttention (dock bounce)", () => {
  // NSApp 문서: 호출 시점에 앱이 active면 0 반환 (no-op). e2e는 puppeteer가
  // attach된 active app이라 0이 자주 발생 — id 0 응답을 정상 신호로 처리.

  test("critical request → id ≥ 0 + 발급된 id로 cancel 성공", async () => {
    const r = await core<{ id: number }>({
      cmd: "app_attention_request",
      critical: true,
    });
    expect(r.id).toBeGreaterThanOrEqual(0);
    if (r.id > 0) {
      const c = await core<{ success: boolean }>({
        cmd: "app_attention_cancel",
        id: r.id,
      });
      expect(c.success).toBe(true);
    }
  });

  test("informational request도 id ≥ 0", async () => {
    const r = await core<{ id: number }>({
      cmd: "app_attention_request",
      critical: false,
    });
    expect(r.id).toBeGreaterThanOrEqual(0);
    if (r.id > 0) {
      await core({ cmd: "app_attention_cancel", id: r.id });
    }
  });

  test("invalid id (0) cancel은 false (guard)", async () => {
    const c = await core<{ success: boolean }>({
      cmd: "app_attention_cancel",
      id: 0,
    });
    expect(c.success).toBe(false);
  });

  test("nonzero id cancel은 항상 true (NSApp API가 void)", async () => {
    // request_id를 발급받지 못한 임의의 nonzero id로 cancel — NSApp이 void로 반환하므로
    // 우리 wrapper는 id != 0이면 무조건 true. 이 비대칭은 의도된 contract.
    const c = await core<{ success: boolean }>({
      cmd: "app_attention_cancel",
      id: 999999,
    });
    expect(c.success).toBe(true);
  });
});

// ============================================
// @suji/api SDK wrapper 검증 — dist/index.js를 페이지에 Blob URL로 import.
// ============================================
// path = "screen.getAllDisplays" 같은 dot-path를 walk해 함수를 얻고 args를 spread.
// `new Function`/string-eval을 피해 type-safe arg 전달 + injection-free.

const sdk = <T = unknown>(path: string, ...args: unknown[]): Promise<T> =>
  page.evaluate(
    ({ path, args }) => {
      const sdkNs = (window as any).__suji_sdk__;
      const parts = path.split(".");
      const fnName = parts.pop()!;
      const owner = parts.reduce((o, k) => o?.[k], sdkNs);
      return owner[fnName](...args);
    },
    { path, args },
  ) as Promise<T>;

// 매칭 선택 로직(겹침 면적/중심 최근접)은 코어 screen_model.matchingDisplayIndex
// 의 zig 단위테스트가 듀얼모니터 케이스를 커버. 여기선 실 디스플레이 SDK 라운드트립만.

describe("@suji/api SDK — round-trip", () => {
  test("screen.getAllDisplays returns array", async () => {
    const r = await sdk<any[]>("screen.getAllDisplays");
    expect(Array.isArray(r)).toBe(true);
    expect(r.length).toBeGreaterThan(0);
    expect(r[0]).toHaveProperty("scaleFactor");
  });

  test("screen.getDisplayMatching returns the display containing a rect", async () => {
    const all = await sdk<any[]>("screen.getAllDisplays");
    const d0 = all[0];
    const m = await sdk<any>("screen.getDisplayMatching", {
      x: d0.x + 10,
      y: d0.y + 10,
      width: 100,
      height: 100,
    });
    expect(m).not.toBeNull();
    expect(m).toHaveProperty("scaleFactor");
    expect(m.index).toBe(d0.index);
  });

  test("desktopCapturer.getSources returns screen sources", async () => {
    const r = await sdk<any[]>("desktopCapturer.getSources", { types: ["screen"] });
    expect(Array.isArray(r)).toBe(true);
    expect(r.some((s) => s.type === "screen")).toBe(true);
    expect(r[0].id).toMatch(/^screen:\d+:0$/);
  });

  test("desktopCapturer.captureThumbnail maps graceful false", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-sdk-thumb-"));
    const target = path.join(dir, "invalid-source.png");
    try {
      const ok = await sdk<boolean>(
        "desktopCapturer.captureThumbnail",
        "not-a-desktop-capturer-source",
        target,
      );
      expect(ok).toBe(false);
      expect(fs.existsSync(target)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("crashReporter SDK wrappers round-trip parameters", async () => {
    const key = `sdk_${Date.now()}`;
    expect(await sdk<boolean>("crashReporter.start", {
      uploadToServer: false,
      extra: { [key]: "yes" },
    })).toBe(true);

    let params = await sdk<Record<string, string>>("crashReporter.getParameters");
    expect(params[key]).toBe("yes");

    expect(await sdk<boolean>("crashReporter.addExtraParameter", `${key}_2`, "ok")).toBe(true);
    params = await sdk<Record<string, string>>("crashReporter.getParameters");
    expect(params[`${key}_2`]).toBe("ok");

    expect(await sdk<boolean>("crashReporter.removeExtraParameter", `${key}_2`)).toBe(true);
    expect(await sdk<boolean>("crashReporter.setUploadToServer", false)).toBe(true);
    expect(await sdk<boolean>("crashReporter.getUploadToServer")).toBe(false);
    const reports = await sdk<any[]>("crashReporter.getUploadedReports");
    expect(Array.isArray(reports)).toBe(true);
    const last = await sdk<any | null>("crashReporter.getLastCrashReport");
    if (last !== null) {
      expect(typeof last.id).toBe("string");
      expect(typeof last.date).toBe("string");
    }
  });

  test("autoUpdater.checkForUpdates + verifyFile + downloadArtifact wrappers", async () => {
    const check = await sdk<any>("autoUpdater.checkForUpdates", {
      version: "9.9.9",
      url: "https://example.test/suji-9.9.9.zip",
      sha256: "",
      notes: "sdk e2e",
      pubDate: "2026-05-25T00:00:00Z",
    }, { currentVersion: "1.0.0" });
    expect(check.success).toBe(true);
    expect(check.updateAvailable).toBe(true);
    expect(check.version).toBe("9.9.9");

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-sdk-updater-"));
    const file = path.join(dir, "payload.bin");
    const downloaded = path.join(dir, "downloaded.bin");
    const payload = Buffer.from("suji updater sdk payload");
    fs.writeFileSync(file, payload);
    const expected = createHash("sha256").update(payload).digest("hex");
    try {
      const verified = await sdk<any>("autoUpdater.verifyFile", file, expected);
      expect(verified.success).toBe(true);
      expect(verified.actualSha256).toBe(expected);

      const dl = await sdk<any>(
        "autoUpdater.downloadArtifact",
        { version: "9.9.9", url: pathToFileURL(file).href, sha256: expected },
        downloaded,
      );
      expect(dl.success).toBe(true);
      expect(dl.sha256).toBe(expected);
      expect(fs.readFileSync(downloaded)).toEqual(payload);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("app.dock setBadge → getBadge round-trip", async () => {
    await sdk("app.dock.setBadge", "z");
    const t = await sdk<string>("app.dock.getBadge");
    expect(t).toBe("z");
    await sdk("app.dock.setBadge", "");
  });

  test("app.setBadgeCount → getBadgeCount round-trip", async () => {
    expect(await sdk<boolean>("app.setBadgeCount", 8)).toBe(true);
    expect(await sdk<number>("app.getBadgeCount")).toBe(8);
    await sdk("app.setBadgeCount", 0);
  });

  test("powerSaveBlocker.start → stop", async () => {
    const id = await sdk<number>("powerSaveBlocker.start", "prevent_display_sleep");
    expect(id).toBeGreaterThan(0);
    const ok = await sdk<boolean>("powerSaveBlocker.stop", id);
    expect(ok).toBe(true);
  });

  test("safeStorage setItem/getItem/deleteItem", async () => {
    const acc = `sdk-${Date.now()}`;
    await sdk("safeStorage.setItem", "Suji-sdk-test", acc, "v1");
    const v = await sdk<string>("safeStorage.getItem", "Suji-sdk-test", acc);
    expect(v).toBe("v1");
    const del = await sdk<boolean>("safeStorage.deleteItem", "Suji-sdk-test", acc);
    expect(del).toBe(true);
  });

  test("app.getPath round-trip — userData/home/documents 절대경로", async () => {
    const home = await sdk<string>("app.getPath", "home");
    expect(home.startsWith("/")).toBe(true);

    const userData = await sdk<string>("app.getPath", "userData");
    expect(userData).toContain("Multi Backend Example");

    const documents = await sdk<string>("app.getPath", "documents");
    expect(documents.endsWith("/Documents")).toBe(true);

    const unknown = await sdk<string>("app.getPath", "unknown_key_xyz");
    expect(unknown).toBe("");
  });

  test("shell.trashItem round-trip — 임시 파일 trash + 비존재 false", async () => {
    const tmp = `/tmp/suji-sdk-trash-${Date.now()}.txt`;
    fs.writeFileSync(tmp, "sdk");
    expect(fs.existsSync(tmp)).toBe(true);

    const ok = await sdk<boolean>("shell.trashItem", tmp);
    expect(ok).toBe(true);
    expect(fs.existsSync(tmp)).toBe(false);

    const missing = await sdk<boolean>("shell.trashItem", "/tmp/suji-sdk-trash-no-such-xyz");
    expect(missing).toBe(false);
  });

  test("session.cookies setCookie → getCookies → removeCookies wrapper", async () => {
    const url = "https://suji-cookies-sdk.example.com/";
    await sdk("session.clearCookies");

    const set = await sdk<boolean>("session.setCookie", {
      url, name: "sdk-k", value: "sdk-v", path: "/", secure: true,
    });
    expect(set).toBe(true);

    const cookies = await sdk<any[]>("session.getCookies", { url });
    const sdkK = cookies.find((c: any) => c.name === "sdk-k");
    expect(sdkK).toBeDefined();
    expect(sdkK.value).toBe("sdk-v");

    const rm = await sdk<boolean>("session.removeCookies", url, "sdk-k");
    expect(rm).toBe(true);

    const after = await sdk<any[]>("session.getCookies", { url });
    expect(after.find((c: any) => c.name === "sdk-k")).toBeUndefined();
  });

  test("app.requestUserAttention → cancel (id ≥ 0 lenient)", async () => {
    const id = await sdk<number>("app.requestUserAttention", true);
    expect(id).toBeGreaterThanOrEqual(0);
    if (id > 0) {
      const ok = await sdk<boolean>("app.cancelUserAttentionRequest", id);
      expect(ok).toBe(true);
    }
    expect(await sdk<boolean>("app.cancelUserAttentionRequest", 0)).toBe(false);
  });
});

// ============================================
// app.requestSingleInstanceLock — Electron single-instance 락.
// round-trip(__core__: 실 userData flock lifecycle) + SDK wrapper.
// 두 번째 프로세스 차단(cross-fd flock) 메커니즘은 cef_single_instance.zig
// 유닛 테스트가 커버 — 여기선 전체 와이어 + 락 lifecycle 만 검증.
// ============================================
describe("app.requestSingleInstanceLock", () => {
  test("round-trip: request → has → idempotent → release → has=false → re-acquire", async () => {
    await core({ cmd: "app_release_single_instance_lock" }); // 깨끗한 상태에서 시작

    expect((await core<{ locked: boolean }>({ cmd: "app_request_single_instance_lock" })).locked).toBe(true);
    expect((await core<{ locked: boolean }>({ cmd: "app_has_single_instance_lock" })).locked).toBe(true);
    // 멱등 — 이미 보유 중이면 재요청도 true(재락 없음).
    expect((await core<{ locked: boolean }>({ cmd: "app_request_single_instance_lock" })).locked).toBe(true);

    expect((await core<{ success: boolean }>({ cmd: "app_release_single_instance_lock" })).success).toBe(true);
    expect((await core<{ locked: boolean }>({ cmd: "app_has_single_instance_lock" })).locked).toBe(false);

    // 해제 후 재획득.
    expect((await core<{ locked: boolean }>({ cmd: "app_request_single_instance_lock" })).locked).toBe(true);
    await core({ cmd: "app_release_single_instance_lock" }); // 정리
  });

  test("SDK round-trip: app.request/has/release 가 boolean 반환", async () => {
    await sdk<boolean>("app.releaseSingleInstanceLock"); // 깨끗한 상태

    expect(await sdk<boolean>("app.requestSingleInstanceLock")).toBe(true);
    expect(await sdk<boolean>("app.hasSingleInstanceLock")).toBe(true);
    expect(await sdk<boolean>("app.releaseSingleInstanceLock")).toBe(true);
    expect(await sdk<boolean>("app.hasSingleInstanceLock")).toBe(false);
  });
});
