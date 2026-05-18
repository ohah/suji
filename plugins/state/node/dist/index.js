"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.state = void 0;
function getBridge() {
    const bridge = globalThis.suji;
    if (!bridge) {
        throw new Error("@suji/plugin-state-node: bridge not available. This module must run inside a Suji app (libnode embedding).");
    }
    return bridge;
}
const withScope = (data, opt) => opt?.scope ? { ...data, scope: opt.scope } : data;
/** invoke("state", {cmd,...}) → 파싱 후 {from:"zig",result|error} 언랩 (Rust/Go 래퍼 동형). */
async function call(cmd, payload) {
    const raw = await getBridge().invoke("state", JSON.stringify({ cmd, ...payload }));
    let resp;
    try {
        resp = JSON.parse(raw);
    }
    catch {
        resp = {};
    }
    if (resp?.error)
        throw new Error(`state: ${resp.error}`);
    return resp?.result;
}
exports.state = {
    async get(key, opt) {
        const r = await call("state:get", withScope({ key }, opt));
        return (r?.value ?? null);
    },
    async set(key, value, opt) {
        await call("state:set", withScope({ key, value }, opt));
    },
    async delete(key, opt) {
        await call("state:delete", withScope({ key }, opt));
    },
    /** scope 명시 시 해당 scope의 user-key만 (prefix 제거). 미지정 시 모든 키. */
    async keys(opt) {
        const r = await call("state:keys", opt?.scope ? { scope: opt.scope } : {});
        return r?.keys ?? [];
    },
    /** scope 지정 시 해당 scope만, 미지정/`{scope:"*"}`이면 전체. */
    async clear(opt) {
        await call("state:clear", opt?.scope ? { scope: opt.scope } : {});
    },
    /**
     * 키 변경 구독 (EventBus). 반환된 함수 호출로 해제.
     * scope 미지정/`"global"` → `state:<key>`, 그 외 → `state:<scope>:<key>`
     * (renderer/Rust 래퍼와 동일 채널 규칙).
     */
    watch(key, callback, opt) {
        const channel = !opt?.scope || opt.scope === "global"
            ? `state:${key}`
            : `state:${opt.scope}:${key}`;
        const bridge = getBridge();
        const subId = bridge.on(channel, (_ch, raw) => {
            let data;
            try {
                data = JSON.parse(raw);
            }
            catch {
                data = raw;
            }
            callback(data);
        });
        return () => bridge.off(subId);
    },
};
