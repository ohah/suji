/**
 * Security-scoped bookmarks E2E — `app.{createSecurityScopedBookmark,
 * start/stopAccessingSecurityScopedResource}` 검증.
 *
 * 전 케이스 자동화 (비파괴 — bookmark 는 in-memory, start/stop 은 부수효과 없음).
 *
 * ⚠️ 정직 경계: 비-sandbox 빌드(기본 `suji dev`)라 `WithSecurityScope` 의 실제
 * 권한 격상은 no-op — 검증되는 건 create/resolve/path round-trip + start/stop
 * lifecycle + accessId 풀 관리 + 에러 분기. MAS sandbox escapement 실효는
 * `suji build --sandbox` + 실 App Store 환경 필요 = 로컬 미검증.
 *
 * 실행: ./tests/e2e/run-security-scoped.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const TMP_PATH = "/tmp/suji-scoped-e2e.txt";

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

beforeAll(async () => {
  await Bun.write(TMP_PATH, "scoped-bookmark-e2e");
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("security_scoped_bookmark_create", () => {
  test("존재하는 path → success + base64 bookmark", async () => {
    const r = await core<{ success: boolean; bookmark?: string }>({
      cmd: "security_scoped_bookmark_create",
      path: TMP_PATH,
    });
    expect(r.success).toBe(true);
    expect(typeof r.bookmark).toBe("string");
    expect(r.bookmark!.length).toBeGreaterThan(0);
    // base64 알파벳만 (JSON-safe).
    expect(/^[A-Za-z0-9+/=]+$/.test(r.bookmark!)).toBe(true);
  });

  test("존재하지 않는 path → success:false", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "security_scoped_bookmark_create",
      path: "/nonexistent/suji-xyz-zzz",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("create");
  });
});

describe("start/stop lifecycle", () => {
  test("create → start(해소 path round-trip) → stop", async () => {
    const c = await core<{ success: boolean; bookmark: string }>({
      cmd: "security_scoped_bookmark_create",
      path: TMP_PATH,
    });
    expect(c.success).toBe(true);

    const s = await core<{ success: boolean; id: number; path: string; stale: boolean }>({
      cmd: "security_scoped_access_start",
      bookmark: c.bookmark,
    });
    expect(s.success).toBe(true);
    expect(s.id).toBeGreaterThan(0);
    expect(s.path).toContain("suji-scoped-e2e.txt");
    expect(typeof s.stale).toBe("boolean");

    const st = await core<{ success: boolean }>({
      cmd: "security_scoped_access_stop",
      id: s.id,
    });
    expect(st.success).toBe(true);
  });

  test("stop(이미 해제된 id) → success:false (이중 해제 가드)", async () => {
    const c = await core<{ bookmark: string }>({
      cmd: "security_scoped_bookmark_create",
      path: TMP_PATH,
    });
    const s = await core<{ id: number }>({
      cmd: "security_scoped_access_start",
      bookmark: c.bookmark,
    });
    expect((await core<{ success: boolean }>({ cmd: "security_scoped_access_stop", id: s.id })).success).toBe(true);
    expect((await core<{ success: boolean }>({ cmd: "security_scoped_access_stop", id: s.id })).success).toBe(false);
  });
});

describe("error 분기", () => {
  test("stop(0) → success:false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "security_scoped_access_stop", id: 0 });
    expect(r.success).toBe(false);
  });

  test("stop(풀 범위 밖 id) → success:false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "security_scoped_access_stop", id: 99999 });
    expect(r.success).toBe(false);
  });

  test("start(깨진 base64) → success:false (resolve 실패)", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "security_scoped_access_start",
      bookmark: "!!!not-base64!!!",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("resolve");
  });

  test("start(유효 base64지만 bookmark 아님) → success:false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "security_scoped_access_start",
      bookmark: btoa("this is not a bookmark blob"),
    });
    expect(r.success).toBe(false);
  });
});
