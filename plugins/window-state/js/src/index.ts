/**
 * @suji/plugin-window-state — 창 위치/크기/최대화 상태 저장·복원 (Electron/Tauri window-state 동등).
 *
 * 코어 백엔드 windows API(getBounds/isMaximized/setBounds/maximize) 조합 + 파일 영속.
 * 호출 창은 자동 감지(코어가 `__window` 주입) — windowId 생략 가능.
 *
 * ```ts
 * import { windowState } from '@suji/plugin-window-state';
 *
 * // 시작 시 복원
 * await windowState.restoreState();              // key 생략 → 창 name 또는 "main"
 * // 종료 직전 저장 (move/resize 이벤트가 없어 명시 저장)
 * suji.on('app:before-quit', () => windowState.saveState());
 *
 * // 멀티 윈도우 — key 로 구분
 * await windowState.restoreState({ key: 'settings' });
 * ```
 *
 * 정직 경계: 코어에 window move/resize 이벤트가 없어 자동 추적은 불가 — saveState 를
 *   적절한 시점(app:before-quit / window:close)에 명시 호출한다.
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

async function call(channel: string, data: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(channel, data);
  if (resp?.error) throw new Error(`window-state: ${resp.error}`);
  return resp?.result ?? resp;
}

export interface WindowState {
  x: number;
  y: number;
  width: number;
  height: number;
  maximized: boolean;
}

export interface SaveOptions {
  /** 저장 슬롯 키. 생략 시 창 name 또는 "main". 멀티 윈도우 구분용. */
  key?: string;
  /** 대상 창 id. 생략 시 호출 창(렌더러). Node 백엔드는 창이 없어 명시 필요. */
  windowId?: number;
}

/** key/windowId 가 정의됐을 때만 payload 에 포함 (wire 최소화). get/clear 의 opts 는
 *  타입이 key-only(Pick) 라 windowId 는 애초에 부재 → 무조건 복사해도 동일. */
function payload(opts?: SaveOptions): Record<string, unknown> {
  const p: Record<string, unknown> = {};
  if (opts?.key !== undefined) p.key = opts.key;
  if (opts?.windowId !== undefined) p.windowId = opts.windowId;
  return p;
}

export const windowState = {
  /** 현재 창(또는 windowId) bounds+maximized 를 저장. */
  async saveState(opts?: SaveOptions): Promise<void> {
    await call("window-state:save", payload(opts));
  },
  /** 저장된 state 를 창에 적용. 저장값이 없으면 false. */
  async restoreState(opts?: SaveOptions): Promise<boolean> {
    const r = await call("window-state:restore", payload(opts));
    return Boolean(r?.restored);
  },
  /** 저장된 state 조회(적용 X). 없으면 null. */
  async getState(opts?: Pick<SaveOptions, "key">): Promise<WindowState | null> {
    const r = await call("window-state:get", payload(opts));
    return (r?.state ?? null) as WindowState | null;
  },
  /** 저장된 state 삭제. */
  async clearState(opts?: Pick<SaveOptions, "key">): Promise<void> {
    await call("window-state:clear", payload(opts));
  },
};
