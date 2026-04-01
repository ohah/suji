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
function getBridge() {
    const bridge = window.__suji__;
    if (!bridge)
        throw new Error("Suji bridge not available.");
    return bridge;
}
export const state = {
    async get(key) {
        const result = await getBridge().invoke("state:get", { key });
        return result?.result?.value ?? null;
    },
    async set(key, value) {
        await getBridge().invoke("state:set", { key, value });
    },
    async delete(key) {
        await getBridge().invoke("state:delete", { key });
    },
    async keys() {
        const result = await getBridge().invoke("state:keys");
        return result?.result?.keys ?? [];
    },
    async clear() {
        await getBridge().invoke("state:clear");
    },
    watch(key, callback) {
        return getBridge().on(`state:${key}`, callback);
    },
};
