/**
 * @suji/plugin-window-state-node — 창 상태 저장·복원 for Suji Node backends.
 * Wire contract 은 renderer `@suji/plugin-window-state` 와 동일.
 *
 * ⚠️ Node 백엔드는 창 컨텍스트가 없으므로 `windowId` 를 명시해야 한다(렌더러는 자동 감지).
 *
 * ```ts
 * const { windowState } = require('@suji/plugin-window-state-node');
 * await windowState.restoreState({ key: 'main', windowId: 1 });
 * await windowState.saveState({ key: 'main', windowId: 1 });
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-window-state-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("window-state", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`window-state: ${resp.error}`);
  return resp?.result;
}

export interface WindowState {
  x: number;
  y: number;
  width: number;
  height: number;
  maximized: boolean;
}

export interface SaveOptions {
  /** 저장 슬롯 키. 생략 시 "main". 멀티 윈도우 구분용. */
  key?: string;
  /** 대상 창 id. Node 백엔드는 창 컨텍스트가 없어 명시 필요. */
  windowId?: number;
}

/** get/clear 의 opts 는 타입이 key-only(Pick) 라 windowId 는 부재 → 무조건 복사해도 동일. */
function payload(opts?: SaveOptions): Record<string, unknown> {
  const p: Record<string, unknown> = {};
  if (opts?.key !== undefined) p.key = opts.key;
  if (opts?.windowId !== undefined) p.windowId = opts.windowId;
  return p;
}

export const windowState = {
  async saveState(opts?: SaveOptions): Promise<void> {
    await call("window-state:save", payload(opts));
  },
  async restoreState(opts?: SaveOptions): Promise<boolean> {
    const r = await call("window-state:restore", payload(opts));
    return Boolean(r?.restored);
  },
  async getState(opts?: Pick<SaveOptions, "key">): Promise<WindowState | null> {
    const r = await call("window-state:get", payload(opts));
    return (r?.state ?? null) as WindowState | null;
  },
  async clearState(opts?: Pick<SaveOptions, "key">): Promise<void> {
    await call("window-state:clear", payload(opts));
  },
};
