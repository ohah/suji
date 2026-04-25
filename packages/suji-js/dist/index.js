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
 * 이벤트 발신 (Electron: ipcRenderer.send / webContents.send)
 *
 * @param options.to - 특정 창 id 지정 시 해당 창에만. 생략 시 모든 창으로 브로드캐스트.
 */
export function send(event, data, options) {
    getBridge().emit(event, JSON.stringify(data ?? {}), options?.to);
}
/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export function off(event) {
    const bridge = window.__suji__;
    if (bridge?.off)
        bridge.off(event);
}
async function coreCall(request) {
    const raw = await getBridge().core(JSON.stringify(request));
    return (typeof raw === "string" ? JSON.parse(raw) : raw);
}
export const windows = {
    /**
     * 새 창 생성. Phase 3 옵션 풀 지원 — suji.json `windows[]` 항목과 동일한 키.
     * @returns `{ windowId }` — 후속 setTitle/setBounds 및 `send(_, { to: windowId })`에 사용
     */
    create(opts = {}) {
        return coreCall({ cmd: "create_window", ...opts });
    },
    /** 창 타이틀 변경 */
    setTitle(windowId, title) {
        return coreCall({ cmd: "set_title", windowId, title });
    },
    /** 창 크기/위치 변경. width/height=0이면 현재 유지 */
    setBounds(windowId, bounds) {
        return coreCall({ cmd: "set_bounds", windowId, ...bounds });
    },
};
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
