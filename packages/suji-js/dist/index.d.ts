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
export interface SendOptions {
    /** 특정 창(window id)에만 전달. 생략 시 모든 창으로 브로드캐스트 (Electron `webContents.send` 대응) */
    to?: number;
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
 * 이벤트 발신 (Electron: ipcRenderer.send / webContents.send)
 *
 * @param options.to - 특정 창 id 지정 시 해당 창에만. 생략 시 모든 창으로 브로드캐스트.
 */
export declare function send(event: string, data: unknown, options?: SendOptions): void;
/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export declare function off(event: string): void;
export type TitleBarStyle = "default" | "hidden" | "hiddenInset";
export interface WindowOptions {
    /** 창 타이틀 */
    title?: string;
    /** 초기 로드 URL. 생략 시 frontend dev_url/dist 자동 선택 */
    url?: string;
    /** WM 등록 이름 (singleton 키). 동일 name이 이미 있으면 기존 창 id 반환 */
    name?: string;
    width?: number;
    height?: number;
    /** 초기 위치 (px). 0/생략 시 OS cascade 자동 배치 */
    x?: number;
    y?: number;
    /** 부모 창 id 직접 지정 (parent보다 우선) */
    parentId?: number;
    /** 부모 창 이름 — 코어가 이름→id 변환 */
    parent?: string;
    /** false면 frameless (타이틀바/리사이즈 핸들 제거) */
    frame?: boolean;
    /** true면 투명 NSWindow + clear background (HTML body도 transparent여야 의미) */
    transparent?: boolean;
    /** 16진수 RGB(A) (`#FFFFFF` / `#FFFFFFFF`). transparent와 함께면 transparent 우선 */
    backgroundColor?: string;
    titleBarStyle?: TitleBarStyle;
    /** 사용자 리사이즈 허용 (frame=false일 땐 무시) */
    resizable?: boolean;
    /** NSFloatingWindowLevel — 일반 창 위 항상 표시 */
    alwaysOnTop?: boolean;
    minWidth?: number;
    minHeight?: number;
    maxWidth?: number;
    maxHeight?: number;
    /** 시작 시 전체화면 */
    fullscreen?: boolean;
}
export interface CreateWindowResponse {
    cmd: "create_window";
    from: "zig-core";
    windowId: number;
}
export interface WindowOpResponse {
    cmd: string;
    from: "zig-core";
    windowId: number;
    ok: boolean;
}
export interface SetBoundsArgs {
    x?: number;
    y?: number;
    width?: number;
    height?: number;
}
export interface GetUrlResponse extends WindowOpResponse {
    cmd: "get_url";
    url: string | null;
}
export interface IsLoadingResponse extends WindowOpResponse {
    cmd: "is_loading";
    loading: boolean;
}
export interface IsDevToolsOpenedResponse extends WindowOpResponse {
    cmd: "is_dev_tools_opened";
    opened: boolean;
}
export declare const windows: {
    /**
     * 새 창 생성. Phase 3 옵션 풀 지원 — suji.json `windows[]` 항목과 동일한 키.
     * @returns `{ windowId }` — 후속 setTitle/setBounds 및 `send(_, { to: windowId })`에 사용
     */
    create(opts?: WindowOptions): Promise<CreateWindowResponse>;
    /** 창 타이틀 변경 */
    setTitle(windowId: number, title: string): Promise<WindowOpResponse>;
    /** 창 크기/위치 변경. width/height=0이면 현재 유지 */
    setBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse>;
    /** 창에 새 URL 로드 (Electron `webContents.loadURL`) */
    loadURL(windowId: number, url: string): Promise<WindowOpResponse>;
    /** 현재 페이지 reload. ignoreCache=true면 disk 캐시 무시 */
    reload(windowId: number, ignoreCache?: boolean): Promise<WindowOpResponse>;
    /** 렌더러에서 임의 JS 실행 (Electron `webContents.executeJavaScript`).
     *  결과 회신은 미지원 — fire-and-forget. 결과가 필요하면 JS 측에서 `suji.send`로 회신. */
    executeJavaScript(windowId: number, code: string): Promise<WindowOpResponse>;
    /** 현재 main frame URL 조회 (캐시된 값). 캐시 미스면 null */
    getURL(windowId: number): Promise<GetUrlResponse>;
    /** 현재 로딩 중인지 조회 (Electron `webContents.isLoading`) */
    isLoading(windowId: number): Promise<IsLoadingResponse>;
    /** DevTools 열기 — 이미 열려있으면 멱등 no-op */
    openDevTools(windowId: number): Promise<WindowOpResponse>;
    /** DevTools 닫기 — 이미 닫혀있으면 no-op */
    closeDevTools(windowId: number): Promise<WindowOpResponse>;
    /** DevTools 열려있는지 조회 (Electron `webContents.isDevToolsOpened`) */
    isDevToolsOpened(windowId: number): Promise<IsDevToolsOpenedResponse>;
    /** DevTools 토글 — F12 단축키와 동일 동작 */
    toggleDevTools(windowId: number): Promise<WindowOpResponse>;
};
/**
 * 여러 백엔드에 동시 요청
 */
export declare function fanout<T = unknown>(backends: string[], channel: string, data?: Record<string, unknown>): Promise<T>;
/**
 * 체인 호출 (A → Core → B)
 */
export declare function chain<T = unknown>(from: string, to: string, channel: string, data?: Record<string, unknown>): Promise<T>;
export {};
