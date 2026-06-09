/**
 * @suji/plugin-positioner-node — 창 위치 배치 for Suji Node backends.
 * Wire contract 은 renderer `@suji/plugin-positioner` 와 동일.
 *
 * ⚠️ Node 백엔드는 창 컨텍스트가 없으므로 `windowId` 를 명시해야 한다.
 *
 * ```ts
 * const { positioner } = require('@suji/plugin-positioner-node');
 * await positioner.move('center', { windowId: 1 });
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-positioner-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("positioner", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`positioner: ${resp.error}`);
  return resp?.result;
}

export type Position =
  | "center"
  | "top-left"
  | "top-right"
  | "bottom-left"
  | "bottom-right"
  | "top-center"
  | "bottom-center"
  | "left-center"
  | "right-center"
  | "at-cursor"
  | "tray-center";

export interface MoveOptions {
  /** 대상 창 id. Node 백엔드는 창 컨텍스트가 없어 명시 필요. */
  windowId?: number;
  /** tray-center 위치에 필요한 트레이 id. */
  trayId?: number;
}

export const positioner = {
  async move(position: Position, opts?: MoveOptions): Promise<{ x: number; y: number }> {
    const payload: Record<string, unknown> = { position };
    if (opts?.windowId !== undefined) payload.windowId = opts.windowId;
    if (opts?.trayId !== undefined) payload.trayId = opts.trayId;
    const r = await call("positioner:move", payload);
    return { x: Number(r?.x ?? 0), y: Number(r?.y ?? 0) };
  },
};
