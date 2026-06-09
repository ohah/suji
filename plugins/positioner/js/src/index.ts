/**
 * @suji/plugin-positioner — 창을 화면/트레이/커서 기준 위치로 배치 (Tauri positioner 동등).
 *
 * 코어 screen/windows/tray API 조합 — 호출 창의 work area(현재 창이 있는 디스플레이)
 * 안에서 위치를 계산해 setBounds. 호출 창은 코어가 `__window` 자동 주입.
 *
 * ```ts
 * import { positioner } from '@suji/plugin-positioner';
 *
 * await positioner.move('center');            // 현재 디스플레이 work area 중앙
 * await positioner.move('bottom-right');      // 우하단
 * await positioner.move('at-cursor');         // 커서 위치
 * await positioner.move('tray-center', { trayId }); // 트레이 아이콘 아래 (menu-bar 앱)
 * ```
 *
 * ⚠️ tray-center / at-cursor 의 tray/cursor 좌표는 macOS 기준이 가장 정확하다
 *   (tray.getBounds 는 macOS only). multi-display 는 primary 높이 기준 전역 변환으로 정확.
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
  if (resp?.error) throw new Error(`positioner: ${resp.error}`);
  return resp?.result ?? resp;
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
  /** 대상 창 id. 생략 시 호출 창(렌더러). Node 백엔드는 창이 없어 명시 필요. */
  windowId?: number;
  /** tray-center 위치에 필요한 트레이 id (suji.tray.create 반환값). */
  trayId?: number;
}

export const positioner = {
  /** 창을 position 으로 이동. 적용된 좌상단 좌표 {x, y} 반환. */
  async move(position: Position, opts?: MoveOptions): Promise<{ x: number; y: number }> {
    const data: Record<string, unknown> = { position };
    if (opts?.windowId !== undefined) data.windowId = opts.windowId;
    if (opts?.trayId !== undefined) data.trayId = opts.trayId;
    const r = await call("positioner:move", data);
    return { x: Number(r?.x ?? 0), y: Number(r?.y ?? 0) };
  },
};
