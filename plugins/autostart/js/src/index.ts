/**
 * @suji/plugin-autostart — launch at login for Suji renderer (Tauri `autostart` 패리티).
 *
 * ```ts
 * import { autostart } from '@suji/plugin-autostart';
 * await autostart.enable();
 * const on = await autostart.isEnabled();
 * await autostart.disable();
 * ```
 *
 * macOS: ~/Library/LaunchAgents plist. Linux: ~/.config/autostart .desktop.
 * Windows/기타: 미지원(`supported:false`). label 기본 "suji-app".
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

export interface AutostartOpts {
  /** autostart 항목 식별자 (plist/desktop 파일명). 앱별 고유값 권장. 기본 "suji-app". */
  label?: string;
}

const withLabel = (opt?: AutostartOpts) => (opt?.label ? { label: opt.label } : {});

export const autostart = {
  /** 로그인 시 자동 실행 등록. macOS 는 다음 로그인부터 발효. */
  async enable(opt?: AutostartOpts): Promise<boolean> {
    const r = await getBridge().invoke("autostart:enable", withLabel(opt));
    return r?.result?.ok === true;
  },
  /** 자동 실행 해제 (멱등). */
  async disable(opt?: AutostartOpts): Promise<boolean> {
    const r = await getBridge().invoke("autostart:disable", withLabel(opt));
    return r?.result?.ok === true;
  },
  /** 현재 자동 실행 등록 여부. */
  async isEnabled(opt?: AutostartOpts): Promise<boolean> {
    const r = await getBridge().invoke("autostart:isEnabled", withLabel(opt));
    return r?.result?.enabled === true;
  },
};
