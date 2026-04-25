/**
 * @suji/plugin-state — State Plugin for Suji Renderer
 *
 * KV Store with JSON file persistence.
 * Phase 2.5: scope 지원 — global / window:N / window 자동 / session:*.
 *
 * ```ts
 * import { state } from '@suji/plugin-state';
 *
 * await state.set("user", { name: "yoon" });           // global
 * await state.set("layout", "split", { scope: "window" }); // 호출 창에만
 * const layout = await state.get("layout", { scope: "window" });
 * state.watch("user", (val) => console.log(val));
 * ```
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
  on(event: string, cb: (data: unknown) => void): () => void;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

/** scope: 생략하면 global. "window"는 호출 창 id로 자동 치환 (sender → "window:N"). */
export interface ScopeOpt {
  scope?: string;
}

const withScope = (data: Record<string, unknown>, opt?: ScopeOpt) =>
  opt?.scope ? { ...data, scope: opt.scope } : data;

export const state = {
  async get<T = unknown>(key: string, opt?: ScopeOpt): Promise<T | null> {
    const result = await getBridge().invoke("state:get", withScope({ key }, opt)) as any;
    return result?.result?.value ?? null;
  },

  async set(key: string, value: unknown, opt?: ScopeOpt): Promise<void> {
    await getBridge().invoke("state:set", withScope({ key, value }, opt));
  },

  async delete(key: string, opt?: ScopeOpt): Promise<void> {
    await getBridge().invoke("state:delete", withScope({ key }, opt));
  },

  /** scope 명시 시 해당 scope의 user-key만 (prefix 제거). 미지정 시 모든 키. */
  async keys(opt?: ScopeOpt): Promise<string[]> {
    const result = await getBridge().invoke("state:keys", opt?.scope ? { scope: opt.scope } : {}) as any;
    return result?.result?.keys ?? [];
  },

  /** scope 지정 시 해당 scope만, 미지정/`{scope:"*"}`이면 전체. */
  async clear(opt?: ScopeOpt): Promise<void> {
    await getBridge().invoke("state:clear", opt?.scope ? { scope: opt.scope } : {});
  },

  /**
   * 키 변경 구독.
   * scope 미지정 → "state:<key>" (global 채널, 기존 호환).
   * scope 지정   → "state:<scope>:<key>" — global이면 단축형으로 폴백 일관성 유지.
   */
  watch(key: string, callback: (value: unknown) => void, opt?: ScopeOpt): () => void {
    const channel = !opt?.scope || opt.scope === "global"
      ? `state:${key}`
      : `state:${opt.scope}:${key}`;
    return getBridge().on(channel, callback);
  },
};
