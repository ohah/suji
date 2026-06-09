/**
 * 공식 positioner 플러그인 통합 e2e (실 CEF 창 + 실 디스플레이 지오메트리).
 *
 * 검증 범위:
 *   1. renderer 가 __suji__.invoke('positioner:move', {position}) → 플러그인이 실
 *      getBounds + getAllDisplays 로 work area 를 구해 setBounds 까지 라운드트립
 *   2. 좌표 단조성: top-left < bottom-right(x,y 모두), center 는 그 사이 — 지오메트리 정확
 *   3. at-cursor / unknown position graceful
 *
 * Wrapper wire shape 은 `bun test plugins/positioner/{js,node}/src` 가 별도 검증.
 * 단위 테스트는 screen/window API 가 없어 graceful-error 표면만 커버 — 실 좌표 계산은
 * 이 파일이 유일하게 검증한다.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const sujiInvoke = <T = any>(channel: string, payload?: unknown): Promise<T> =>
  page.evaluate(
    (r) => (window as unknown as { __suji__: { invoke: (ch: string, d?: unknown) => unknown } }).__suji__
      .invoke(r.channel as string, r.payload as unknown),
    { channel, payload },
  ) as Promise<T>;

const move = (position: string): Promise<{ result?: { ok?: boolean; x?: number; y?: number }; error?: string }> =>
  sujiInvoke("positioner:move", { position });

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
  await page.waitForFunction(() => typeof (window as any).__suji__ !== "undefined", { timeout: 10000 });
  // 창을 work area 보다 확실히 작게 축소 — 그래야 모서리 위치들이 서로 구분돼 단조성이
  // 성립한다(헤드리스/소형 가상 디스플레이에서 1024x768 창이 화면을 꽉 채워 모두 한
  // 모서리로 clamp 되는 flake 방지). set_bounds 는 windowId 명시 필요 → getFocusedWindow.
  const fw = await sujiInvoke<{ windowId?: number }>("get_focused_window");
  const wid = fw?.windowId;
  if (typeof wid === "number") {
    await sujiInvoke("set_bounds", { windowId: wid, x: 80, y: 80, width: 520, height: 380 });
  }
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("positioner plugin: live geometry", () => {
  test("screen-relative positions are monotonic (top-left < bottom-right, center between)", async () => {
    const tl = await move("top-left");
    expect(tl?.error).toBeUndefined();
    expect(tl?.result?.ok).toBe(true);

    const br = await move("bottom-right");
    expect(br?.result?.ok).toBe(true);

    const c = await move("center");
    expect(c?.result?.ok).toBe(true);

    const tlx = tl!.result!.x!, tly = tl!.result!.y!;
    const brx = br!.result!.x!, bry = br!.result!.y!;
    const cx = c!.result!.x!, cy = c!.result!.y!;

    // bottom-right 는 top-left 보다 우/하 (창이 work area 보다 작다는 전제 — 1024x768 창).
    expect(brx).toBeGreaterThan(tlx);
    expect(bry).toBeGreaterThan(tly);
    // center 는 두 극단 사이.
    expect(cx).toBeGreaterThanOrEqual(tlx);
    expect(cx).toBeLessThanOrEqual(brx);
    expect(cy).toBeGreaterThanOrEqual(tly);
    expect(cy).toBeLessThanOrEqual(bry);
  });

  test("at-cursor returns coords (graceful)", async () => {
    const r = await move("at-cursor");
    expect(r?.error).toBeUndefined();
    expect(r?.result?.ok).toBe(true);
    expect(typeof r?.result?.x).toBe("number");
    expect(typeof r?.result?.y).toBe("number");
  });

  test("unknown position → error", async () => {
    const r = await move("nonsense-corner");
    expect(r?.error ?? r?.result).toBeDefined();
    // 에러 객체 또는 result.error 둘 중 하나로 거부.
    const errStr = JSON.stringify(r);
    expect(errStr).toContain("unknown position");
  });
});
