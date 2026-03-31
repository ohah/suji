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
export interface InvokeOptions {
    /** 특정 백엔드 지정 (생략 시 자동 라우팅) */
    target?: string;
}
type Listener = (data: unknown) => void;
/**
 * 백엔드 핸들러 호출 (Electron: ipcRenderer.invoke)
 *
 * @param channel - 핸들러 채널 이름
 * @param data - 요청 데이터 (옵셔널)
 * @param options - { target: "backend" } 명시적 백엔드 지정 (옵셔널)
 */
export declare function invoke<T = unknown>(channel: string, data?: Record<string, unknown>, options?: InvokeOptions): Promise<T>;
/**
 * 이벤트 구독 (Electron: ipcRenderer.on)
 *
 * @returns 리스너 해제 함수
 */
export declare function on(event: string, callback: Listener): () => void;
/**
 * 이벤트 한 번만 구독 (Electron: ipcRenderer.once)
 *
 * @returns 리스너 해제 함수
 */
export declare function once(event: string, callback: Listener): () => void;
/**
 * 이벤트 발신 (Electron: ipcRenderer.send)
 */
export declare function send(event: string, data: unknown): void;
/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export declare function off(event: string): void;
/**
 * 여러 백엔드에 동시 요청
 */
export declare function fanout<T = unknown>(backends: string[], channel: string, data?: Record<string, unknown>): Promise<T>;
/**
 * 체인 호출 (A → Core → B)
 */
export declare function chain<T = unknown>(from: string, to: string, channel: string, data?: Record<string, unknown>): Promise<T>;
export {};
