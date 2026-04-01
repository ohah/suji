/**
 * @suji/plugin-state — State Plugin for Suji Renderer
 *
 * KV Store with JSON file persistence.
 *
 * ```ts
 * import { state } from '@suji/plugin-state';
 *
 * await state.set("user", { name: "yoon" });
 * const user = await state.get("user");
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

export const state = {
  async get<T = unknown>(key: string): Promise<T | null> {
    const result = await getBridge().invoke("state:get", { key }) as any;
    return result?.result?.value ?? null;
  },

  async set(key: string, value: unknown): Promise<void> {
    await getBridge().invoke("state:set", { key, value });
  },

  async delete(key: string): Promise<void> {
    await getBridge().invoke("state:delete", { key });
  },

  async keys(): Promise<string[]> {
    const result = await getBridge().invoke("state:keys") as any;
    return result?.result?.keys ?? [];
  },

  async clear(): Promise<void> {
    await getBridge().invoke("state:clear");
  },

  watch(key: string, callback: (value: unknown) => void): () => void {
    return getBridge().on(`state:${key}`, callback);
  },
};
