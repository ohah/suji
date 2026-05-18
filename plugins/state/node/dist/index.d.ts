/**
 * @suji/plugin-state-node — State Plugin for Suji Node.js backends
 *
 * KV Store with JSON file persistence. The backend counterpart of the
 * renderer `@suji/plugin-state` — same wire contract as the Rust
 * (`suji-plugin-state`) / Go (`suji-plugin-state`) wrappers: route through
 * the `state` backend with the cmd embedded in the request JSON.
 *
 * ```ts
 * const { state } = require('@suji/plugin-state-node');
 *
 * await state.set("user", { name: "yoon" });               // global
 * await state.set("layout", "split", { scope: "window:1" }); // 특정 창
 * const layout = await state.get("layout", { scope: "window:1" });
 * const cancel = state.watch("user", (val) => console.log(val));
 * ```
 */
/** scope: 생략하면 global. "window:N"/"session:*" 등 명시 가능. */
export interface ScopeOpt {
    scope?: string;
}
export declare const state: {
    get<T = unknown>(key: string, opt?: ScopeOpt): Promise<T | null>;
    set(key: string, value: unknown, opt?: ScopeOpt): Promise<void>;
    delete(key: string, opt?: ScopeOpt): Promise<void>;
    /** scope 명시 시 해당 scope의 user-key만 (prefix 제거). 미지정 시 모든 키. */
    keys(opt?: ScopeOpt): Promise<string[]>;
    /** scope 지정 시 해당 scope만, 미지정/`{scope:"*"}`이면 전체. */
    clear(opt?: ScopeOpt): Promise<void>;
    /**
     * 키 변경 구독 (EventBus). 반환된 함수 호출로 해제.
     * scope 미지정/`"global"` → `state:<key>`, 그 외 → `state:<scope>:<key>`
     * (renderer/Rust 래퍼와 동일 채널 규칙).
     */
    watch(key: string, callback: (value: unknown) => void, opt?: ScopeOpt): () => void;
};
