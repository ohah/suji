/**
 * @suji/api — Suji Desktop Framework Frontend API
 *
 * Electron-style IPC for Suji apps.
 *
 * ```ts
 * import { invoke, on, send } from '@suji/api';
 *
 * const result = await invoke("ping");
 * const result = await invoke("greet", { name: "Suji" });
 * const result = await invoke("greet", { name: "Suji" }, { target: "rust" });
 *
 * const cancel = on("data-updated", (data) => console.log(data));
 * send("button-clicked", { button: "save" });
 * cancel(); // remove listener
 * ```
 */
function getBridge() {
    const bridge = window.__suji__;
    if (!bridge)
        throw new Error("Suji bridge not available. Are you running inside a Suji app?");
    return bridge;
}
/**
 * 백엔드 핸들러 호출 (Electron: ipcRenderer.invoke)
 *
 * @param channel - 핸들러 채널 이름
 * @param data - 요청 데이터 (옵셔널)
 * @param options - { target: "backend" } 명시적 백엔드 지정 (옵셔널)
 */
export async function invoke(channel, data, options) {
    return getBridge().invoke(channel, data, options);
}
/**
 * 이벤트 구독 (Electron: ipcRenderer.on)
 *
 * @returns 리스너 해제 함수
 */
export function on(event, callback) {
    return getBridge().on(event, callback);
}
/**
 * 이벤트 한 번만 구독 (Electron: ipcRenderer.once)
 *
 * @returns 리스너 해제 함수
 */
export function once(event, callback) {
    const cancel = getBridge().on(event, (data) => {
        cancel();
        callback(data);
    });
    return cancel;
}
/**
 * 이벤트 발신 (Electron: ipcRenderer.send)
 */
export function send(event, data) {
    getBridge().emit(event, JSON.stringify(data ?? {}));
}
/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export function off(event) {
    const bridge = window.__suji__;
    if (bridge?.off)
        bridge.off(event);
}
/**
 * 여러 백엔드에 동시 요청
 */
export async function fanout(backends, channel, data) {
    const request = JSON.stringify({ cmd: channel, ...data });
    return getBridge().fanout(backends.join(","), request);
}
/**
 * 체인 호출 (A → Core → B)
 */
export async function chain(from, to, channel, data) {
    const request = JSON.stringify({ cmd: channel, ...data });
    return getBridge().chain(from, to, request);
}
