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
export declare const state: {
    get<T = unknown>(key: string): Promise<T | null>;
    set(key: string, value: unknown): Promise<void>;
    delete(key: string): Promise<void>;
    keys(): Promise<string[]>;
    clear(): Promise<void>;
    watch(key: string, callback: (value: unknown) => void): () => void;
};
