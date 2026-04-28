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
/**
 * 사용자 핸들러 타입 declaration. 사용자가 module augmentation으로 채우면 `invoke`가
 * type-safe해진다 (cmd/req/res 모두 추론).
 *
 * ```ts
 * // 사용자 프로젝트의 src/suji.d.ts
 * declare module '@suji/api' {
 *   interface SujiHandlers {
 *     ping: { req: void; res: { msg: string } };
 *     greet: { req: { name: string }; res: string };
 *   }
 * }
 *
 * await invoke('greet', { name: 'Suji' });  // res: string
 * await invoke('ping');                     // req 생략 가능, res: { msg: string }
 * ```
 *
 * 비어있을 때 (default)는 fallback overload가 작동 — 기존 untyped invoke 호환.
 */
export interface SujiHandlers {
}
/** Helper: req가 void/undefined이면 args 생략 가능, 아니면 필수. */
type InvokeArgsForHandler<K extends keyof SujiHandlers & string> = SujiHandlers[K] extends {
    req: infer R;
} ? [R] extends [void | undefined] ? [data?: undefined, options?: InvokeOptions] : [data: R, options?: InvokeOptions] : [data?: unknown, options?: InvokeOptions];
type InvokeRes<K extends keyof SujiHandlers & string> = SujiHandlers[K] extends {
    res: infer R;
} ? R : unknown;
/** 등록된 cmd면 typed args/res, 아니면 untyped fallback. conditional dispatch. */
type InvokeArgs<K extends string> = K extends keyof SujiHandlers & string ? InvokeArgsForHandler<K> : [data?: Record<string, unknown>, options?: InvokeOptions];
type InvokeReturn<K extends string> = K extends keyof SujiHandlers & string ? InvokeRes<K> : unknown;
export interface SendOptions {
    /** 특정 창(window id)에만 전달. 생략 시 모든 창으로 브로드캐스트 (Electron `webContents.send` 대응) */
    to?: number;
}
type Listener = (data: unknown) => void;
/**
 * 백엔드 핸들러 호출 (Electron: ipcRenderer.invoke). SujiHandlers에 등록된 cmd면
 * type-safe (cmd/req/res 추론), 아니면 untyped fallback.
 *
 * @param channel - 핸들러 채널 이름
 * @param data - 요청 데이터 (옵셔널)
 * @param options - { target: "backend" } 명시적 백엔드 지정 (옵셔널)
 */
export declare function invoke<K extends string>(cmd: K, ...rest: InvokeArgs<K>): Promise<InvokeReturn<K>>;
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
export interface ZoomLevelResponse extends WindowOpResponse {
    cmd: "get_zoom_level";
    level: number;
}
export interface ZoomFactorResponse extends WindowOpResponse {
    cmd: "get_zoom_factor";
    factor: number;
}
export interface ViewOptions {
    /** view를 합성할 host 창 id. live & .window이어야 함 */
    hostId: number;
    /** 초기 로드 URL */
    url?: string;
    /** view 식별/디버깅 이름 (by_name 등록 X — view는 host scope) */
    name?: string;
    /** host contentView 좌표계의 view 위치/크기 (top-left). 기본 {0, 0, 800, 600} */
    bounds?: SetBoundsArgs;
}
export interface CreateViewResponse {
    cmd: "create_view";
    from: "zig-core";
    viewId: number;
}
/** view 전용 op 응답 — `windowId` 키 대신 `viewId`로 응답. webContents 메서드(load_url 등)
 *  는 그대로 windowId 키 사용 (id 풀 공유). */
export interface ViewOpResponse {
    cmd: string;
    from: "zig-core";
    viewId: number;
    ok: boolean;
}
export interface GetChildViewsResponse {
    cmd: "get_child_views";
    from: "zig-core";
    hostId: number;
    ok: boolean;
    /** z-order 순서 (0=bottom, 마지막=top). 빈 배열이면 host에 view 없음 */
    viewIds: number[];
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
    /** 줌 레벨 변경. Electron 호환 — 0 = 100%, 1 = 120%, -1 = 1/1.2 (logarithmic) */
    setZoomLevel(windowId: number, level: number): Promise<WindowOpResponse>;
    getZoomLevel(windowId: number): Promise<ZoomLevelResponse>;
    /** 줌 factor 변경. 1.0 = 100%, 1.5 = 150% (linear). 내부적으로 level = log(factor)/log(1.2) 변환 */
    setZoomFactor(windowId: number, factor: number): Promise<WindowOpResponse>;
    getZoomFactor(windowId: number): Promise<ZoomFactorResponse>;
    undo(windowId: number): Promise<WindowOpResponse>;
    redo(windowId: number): Promise<WindowOpResponse>;
    cut(windowId: number): Promise<WindowOpResponse>;
    copy(windowId: number): Promise<WindowOpResponse>;
    paste(windowId: number): Promise<WindowOpResponse>;
    selectAll(windowId: number): Promise<WindowOpResponse>;
    /** 페이지 텍스트 검색. 첫 호출은 findNext=false, 이후 같은 단어 다음 매치는 true.
     *  결과 보고는 cef_find_handler_t로 (현재 미노출 — 추후 이벤트). */
    findInPage(windowId: number, text: string, options?: {
        forward?: boolean;
        matchCase?: boolean;
        findNext?: boolean;
    }): Promise<WindowOpResponse>;
    stopFindInPage(windowId: number, clearSelection?: boolean): Promise<WindowOpResponse>;
    /** PDF로 인쇄. CEF는 콜백 기반 async라 두 단계 신호:
     *  1. 코어 IPC 응답 — 요청 접수만 (CEF에 큐잉됨, 파일 아직 X).
     *  2. `window:pdf-print-finished` 이벤트({path, success}) — 실 PDF 작성 완료.
     *  이 SDK는 listener를 path로 매칭해 Promise<{success}>로 단일화 — 사용자는
     *  await 한 번만. 반환된 success가 false면 PDF 작성 실패 (디스크 권한 등).
     *
     *  주의: 같은 path로 동시 인쇄 시 첫 번째 완료 이벤트가 둘 다 resolve. 보통
     *  사용자 시나리오에서 동시 호출 드물어 OK. */
    printToPDF(windowId: number, path: string): Promise<{
        success: boolean;
    }>;
    /** host 창 contentView 안에 새 view 합성 (Electron `WebContentsView`). 자동으로 host의
     *  view_children top에 추가됨 — 이후 addChildView로 z-order 변경 가능. bounds 미지정 시
     *  800x600 @ 0,0 (코어의 parseBoundsFromJson은 누락 키를 0으로 채워 SDK가 default 적용). */
    createView(opts: ViewOptions): Promise<CreateViewResponse>;
    /** view 파괴. host의 view_children에서 자동 제거 + `window:view-destroyed` 이벤트 */
    destroyView(viewId: number): Promise<ViewOpResponse>;
    /** view를 host children에 추가/재배치. index 생략 시 top. 같은 view 재호출 시 위치 갱신
     *  (Electron WebContentsView idiom). host 이동은 미지원. */
    addChildView(hostId: number, viewId: number, index?: number): Promise<ViewOpResponse>;
    /** view를 host children에서 분리 (destroy X). native에서 setHidden(true). 다시 addChildView
     *  로 같은 host에 붙일 수 있음. */
    removeChildView(hostId: number, viewId: number): Promise<ViewOpResponse>;
    /** addChildView(host, view, undefined) 편의 — Electron `setTopBrowserView` 동등 */
    setTopView(hostId: number, viewId: number): Promise<ViewOpResponse>;
    /** view 위치/크기 변경. host contentView 좌표계 (top-left). */
    setViewBounds(viewId: number, bounds: SetBoundsArgs): Promise<ViewOpResponse>;
    /** view 표시/숨김 토글. CEF host.was_hidden도 함께 호출 (렌더링/입력 일시정지) */
    setViewVisible(viewId: number, visible: boolean): Promise<ViewOpResponse>;
    /** host의 child view id들을 z-order 순서로 조회 (0=bottom, 마지막=top) */
    getChildViews(hostId: number): Promise<GetChildViewsResponse>;
};
export declare const powerMonitor: {
    /** 시스템 유휴 시간 (초). 활성 입력 후 0으로 리셋 (CGEventSource).
     *  Electron `powerMonitor.getSystemIdleTime()` 동등. */
    getSystemIdleTime(): Promise<number>;
};
export declare const clipboard: {
    /** 클립보드의 plain text 읽기. 비어 있거나 non-text면 빈 문자열. */
    readText(): Promise<string>;
    /** 클립보드에 plain text 쓰기. 성공 시 true. */
    writeText(text: string): Promise<boolean>;
    /** 클립보드 비우기. */
    clear(): Promise<boolean>;
    /** HTML read (NSPasteboard `public.html`). 비어 있거나 non-html이면 빈 문자열. */
    readHTML(): Promise<string>;
    /** HTML write — write 시 다른 type (text 등)도 함께 지움. */
    writeHTML(html: string): Promise<boolean>;
};
export interface NotificationOptions {
    title: string;
    body: string;
    /** 사운드 묻음 */
    silent?: boolean;
}
export declare const notification: {
    /** 플랫폼 지원 여부 — 현재 macOS만 true. */
    isSupported(): Promise<boolean>;
    /** 알림 권한 요청 — 첫 호출 시 OS 다이얼로그. 이후 캐시. */
    requestPermission(): Promise<boolean>;
    /** 알림 표시. 반환 `notificationId`로 close 가능. success=false면 권한/번들 문제. */
    show(options: NotificationOptions): Promise<{
        notificationId: string;
        success: boolean;
    }>;
    close(notificationId: string): Promise<boolean>;
};
export interface TrayMenuSeparator {
    type: "separator";
}
export interface TrayMenuItemSpec {
    /** 메뉴에 표시될 텍스트. */
    label: string;
    /** 클릭 시 emit될 이벤트 이름 — `tray:menu-click {trayId, click}` 페이로드의 click 필드. */
    click: string;
}
export type TrayMenuItem = TrayMenuItemSpec | TrayMenuSeparator;
export interface TrayCreateOptions {
    /** 메뉴바에 표시될 텍스트 (icon 미지원 v1라 가시성 위해 권장). */
    title?: string;
    /** 마우스 호버 시 표시될 툴팁. */
    tooltip?: string;
}
export declare const tray: {
    /** 새 시스템 트레이 아이콘 생성. 반환된 trayId로 이후 update/destroy. */
    create(options?: TrayCreateOptions): Promise<{
        trayId: number;
    }>;
    setTitle(trayId: number, title: string): Promise<boolean>;
    setTooltip(trayId: number, tooltip: string): Promise<boolean>;
    /** 트레이 클릭 시 표시될 컨텍스트 메뉴 설정. items는 분리선/일반 항목 혼합 가능.
     *  메뉴 항목 클릭은 `suji.on('tray:menu-click', ({trayId, click}) => ...)` 로 수신. */
    setMenu(trayId: number, items: TrayMenuItem[]): Promise<boolean>;
    destroy(trayId: number): Promise<boolean>;
};
export interface MenuSeparator {
    type: "separator";
}
export interface MenuCommandItem {
    type?: "item";
    label: string;
    click: string;
    enabled?: boolean;
}
export interface MenuCheckboxItem {
    type: "checkbox";
    label: string;
    click: string;
    checked?: boolean;
    enabled?: boolean;
}
export interface MenuSubmenuItem {
    type?: "submenu";
    label: string;
    enabled?: boolean;
    submenu: MenuItem[];
}
export type MenuItem = MenuCommandItem | MenuCheckboxItem | MenuSeparator | MenuSubmenuItem;
export declare const menu: {
    setApplicationMenu(items: MenuItem[]): Promise<boolean>;
    resetApplicationMenu(): Promise<boolean>;
};
export declare const globalShortcut: {
    register(accelerator: string, click: string): Promise<boolean>;
    unregister(accelerator: string): Promise<boolean>;
    unregisterAll(): Promise<boolean>;
    isRegistered(accelerator: string): Promise<boolean>;
};
export declare const shell: {
    /** URL을 시스템 기본 핸들러로 열기 (http(s) → 브라우저, mailto: → 메일 앱 등).
     *  잘못된 URL syntax면 false. */
    openExternal(url: string): Promise<boolean>;
    /** Finder/탐색기에서 파일/폴더 reveal — 부모 폴더 열리고 항목 선택. 경로 없으면 false. */
    showItemInFolder(path: string): Promise<boolean>;
    /** 시스템 비프음. */
    beep(): Promise<boolean>;
    /** 휴지통으로 이동. macOS NSFileManager `trashItemAtURL:`. 실패하면 false. */
    trashItem(path: string): Promise<boolean>;
    /** 파일/폴더를 기본 앱으로 열기 (`openExternal`은 URL용, 이건 로컬 path용).
     *  존재하지 않는 경로는 false. macOS NSWorkspace `openURL:` (file://). */
    openPath(path: string): Promise<boolean>;
};
export declare const nativeTheme: {
    /** 시스템 다크 모드 활성 여부 (Electron `nativeTheme.shouldUseDarkColors`).
     *  macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true. */
    shouldUseDarkColors(): Promise<boolean>;
};
export type FileType = "file" | "directory" | "symlink" | "blockDevice" | "characterDevice" | "fifo" | "socket" | "whiteout" | "door" | "eventPort" | "unknown";
export interface FsStat {
    success: boolean;
    type: FileType;
    size: number;
    /** Last modification time in milliseconds since UTC 1970-01-01 (compatible with `new Date(mtime)`). */
    mtime: number;
}
export interface FsDirEntry {
    name: string;
    type: FileType;
}
export declare const fs: {
    readFile(path: string): Promise<string>;
    writeFile(path: string, text: string): Promise<boolean>;
    stat(path: string): Promise<FsStat>;
    mkdir(path: string, options?: {
        recursive?: boolean;
    }): Promise<boolean>;
    readdir(path: string): Promise<FsDirEntry[]>;
    /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
    rm(path: string, options?: {
        recursive?: boolean;
        force?: boolean;
    }): Promise<boolean>;
};
export type MessageBoxStyle = "none" | "info" | "warning" | "error" | "question";
export interface MessageBoxOptions {
    /** 아이콘 / 시스템 사운드 결정. 기본 "none". */
    type?: MessageBoxStyle;
    /** 창 타이틀. */
    title?: string;
    /** 주 메시지 (필수에 가까움 — 빈 값이면 macOS가 자동 텍스트). */
    message: string;
    /** 보조 메시지 (작은 폰트). */
    detail?: string;
    /** 버튼 레이블 배열. 빈 배열이면 ["OK"]. */
    buttons?: string[];
    /** Enter로 활성화될 버튼 index (기본: 첫 번째). */
    defaultId?: number;
    /** ESC로 활성화될 버튼 index. */
    cancelId?: number;
    /** suppression checkbox 레이블. 빈 문자열이면 체크박스 비활성. */
    checkboxLabel?: string;
    /** 체크박스 초기 상태. */
    checkboxChecked?: boolean;
}
export interface FileFilter {
    /** 필터 그룹 표시명 (현재 macOS UI에는 미반영 — 모든 extensions가 통합 허용). */
    name: string;
    /** 허용 확장자 (점 없이): `["jpg", "png"]`. `"*"`은 모든 파일. */
    extensions: string[];
}
export type OpenDialogProperty = "openFile" | "openDirectory" | "multiSelections" | "showHiddenFiles" | "createDirectory" | "noResolveAliases" | "treatPackageAsDirectory";
export interface OpenDialogOptions {
    title?: string;
    /** 초기 디렉토리 (또는 파일명 포함 경로 — 마지막 segment가 파일명으로 들어감). */
    defaultPath?: string;
    /** 확인 버튼 레이블 ("Open" 대신). */
    buttonLabel?: string;
    /** 다이얼로그 상단 메시지 (macOS 한정 표시). */
    message?: string;
    filters?: FileFilter[];
    /** 기본: ["openFile"]. */
    properties?: OpenDialogProperty[];
}
export type SaveDialogProperty = "showHiddenFiles" | "createDirectory" | "treatPackageAsDirectory";
export interface SaveDialogOptions {
    title?: string;
    defaultPath?: string;
    buttonLabel?: string;
    message?: string;
    /** 파일명 입력란의 레이블. */
    nameFieldLabel?: string;
    /** macOS Finder 태그 입력 필드 표시. */
    showsTagField?: boolean;
    filters?: FileFilter[];
    properties?: SaveDialogProperty[];
}
export declare const dialog: {
    /** 메시지 박스. 첫 인자에 windowId(number) 주면 sheet — 그 창에 부착. 없으면 free-floating.
     *  반환: 사용자가 클릭한 버튼 index + checkbox 상태. */
    showMessageBox(arg1: MessageBoxOptions | number, arg2?: MessageBoxOptions): Promise<{
        response: number;
        checkboxChecked: boolean;
    }>;
    /** 단순 에러 popup (NSAlert critical style + OK 버튼). 응답 없음 — Electron 동등. */
    showErrorBox(title: string, content: string): Promise<void>;
    /** 파일/폴더 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePaths:[]}`. */
    showOpenDialog(arg1?: OpenDialogOptions | number, arg2?: OpenDialogOptions): Promise<{
        canceled: boolean;
        filePaths: string[];
    }>;
    /** 저장 경로 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePath:""}`. */
    showSaveDialog(arg1?: SaveDialogOptions | number, arg2?: SaveDialogOptions): Promise<{
        canceled: boolean;
        filePath: string;
    }>;
    /** Sync 변종 — `response: number`만 반환. windowId 첫 인자 지원. */
    showMessageBoxSync(arg1: MessageBoxOptions | number, arg2?: MessageBoxOptions): Promise<number>;
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string[]`. windowId 첫 인자 지원. */
    showOpenDialogSync(arg1?: OpenDialogOptions | number, arg2?: OpenDialogOptions): Promise<string[] | undefined>;
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string`. windowId 첫 인자 지원. */
    showSaveDialogSync(arg1?: SaveDialogOptions | number, arg2?: SaveDialogOptions): Promise<string | undefined>;
};
export interface WebRequestDetails {
    url: string;
    /** resolve용 internal id — `webRequest.resolve`에 그대로 전달. */
    id: number;
}
export interface WebRequestDecision {
    /** true면 요청 cancel, false/생략이면 통과. */
    cancel?: boolean;
}
type WebRequestListener = (details: WebRequestDetails, callback: (decision: WebRequestDecision) => void) => void;
export declare const webRequest: {
    /** blocklist 패턴 list 갱신 (전체 교체). 빈 list = 모든 요청 통과. 최대 32개, 256자/패턴. */
    setBlockedUrls(patterns: string[]): Promise<number>;
    /**
     * Electron `session.webRequest.onBeforeRequest({urls}, listener)` 동등.
     * filter.urls glob 매칭 시 listener가 비동기 결정 — `callback({ cancel: true })`로 차단,
     * `callback({})`로 통과. callback 호출 안 하면 요청 영원히 hold (timeout fallback 미구현).
     *
     * 한 번에 1 listener만 active — 새로 등록 시 이전 listener detach.
     * filter null 또는 빈 listener는 detach.
     */
    onBeforeRequest(filter: {
        urls: string[];
    } | null, listener: WebRequestListener | null): Promise<void>;
    /** listener 직접 detach (파라미터 없는 onBeforeRequest와 동등). */
    clearListener(): Promise<void>;
};
export interface Display {
    index: number;
    isPrimary: boolean;
    x: number;
    y: number;
    width: number;
    height: number;
    visibleX: number;
    visibleY: number;
    visibleWidth: number;
    visibleHeight: number;
    scaleFactor: number;
}
export declare const screen: {
    /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
    getAllDisplays(): Promise<Display[]>;
    /** 마우스 포인터 화면 좌표 (macOS NSEvent.mouseLocation). bottom-up 좌표계. */
    getCursorScreenPoint(): Promise<{
        x: number;
        y: number;
    }>;
    /** (x,y)를 포함하는 display index. 어느 display에도 포함 안 되면 -1. */
    getDisplayNearestPoint(point: {
        x: number;
        y: number;
    }): Promise<number>;
};
export type PowerSaveBlockerType = "prevent_app_suspension" | "prevent_display_sleep";
export declare const powerSaveBlocker: {
    /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
    start(type: PowerSaveBlockerType): Promise<number>;
    /** start로 받은 id를 해제. unknown id는 false. */
    stop(id: number): Promise<boolean>;
};
export declare const safeStorage: {
    /** service+account에 utf-8 value 저장. 같은 키면 update (idempotent). */
    setItem(service: string, account: string, value: string): Promise<boolean>;
    /** service+account로 저장된 value read. 없으면 빈 문자열. */
    getItem(service: string, account: string): Promise<string>;
    /** service+account 삭제. 존재하지 않아도 true (idempotent). */
    deleteItem(service: string, account: string): Promise<boolean>;
};
export type AppPathName = "home" | "appData" | "userData" | "temp" | "desktop" | "documents" | "downloads";
export declare const app: {
    /** suji.json `app.name` 반환 (Electron `app.getName`). */
    getName(): Promise<string>;
    /** suji.json `app.version` 반환 (Electron `app.getVersion`). */
    getVersion(): Promise<string>;
    /** Electron `app.getPath` 동등. 표준 디렉토리 경로 반환. unknown 키는 빈 문자열. */
    getPath(name: AppPathName): Promise<string>;
    /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
    requestUserAttention(critical?: boolean): Promise<number>;
    /** requestUserAttention으로 받은 id 취소. id == 0은 false (guard). */
    cancelUserAttentionRequest(id: number): Promise<boolean>;
    dock: {
        /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
        setBadge(text: string): Promise<void>;
        /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
        getBadge(): Promise<string>;
    };
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
