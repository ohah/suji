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
    // ── Phase 4-A: webContents 네비/JS ──
    /** 창에 새 URL 로드 (Electron `webContents.loadURL`) */
    loadURL(windowId, url) {
        return coreCall({ cmd: "load_url", windowId, url });
    },
    /** 현재 페이지 reload. ignoreCache=true면 disk 캐시 무시 */
    reload(windowId, ignoreCache = false) {
        return coreCall({ cmd: "reload", windowId, ignoreCache });
    },
    /** 렌더러에서 임의 JS 실행 (Electron `webContents.executeJavaScript`).
     *  결과 회신은 미지원 — fire-and-forget. 결과가 필요하면 JS 측에서 `suji.send`로 회신. */
    executeJavaScript(windowId, code) {
        return coreCall({ cmd: "execute_javascript", windowId, code });
    },
    /** 현재 main frame URL 조회 (캐시된 값). 캐시 미스면 null */
    getURL(windowId) {
        return coreCall({ cmd: "get_url", windowId });
    },
    /** 현재 로딩 중인지 조회 (Electron `webContents.isLoading`) */
    isLoading(windowId) {
        return coreCall({ cmd: "is_loading", windowId });
    },
    /** DevTools 열기 — 이미 열려있으면 멱등 no-op */
    openDevTools(windowId) {
        return coreCall({ cmd: "open_dev_tools", windowId });
    },
    /** DevTools 닫기 — 이미 닫혀있으면 no-op */
    closeDevTools(windowId) {
        return coreCall({ cmd: "close_dev_tools", windowId });
    },
    /** DevTools 열려있는지 조회 (Electron `webContents.isDevToolsOpened`) */
    isDevToolsOpened(windowId) {
        return coreCall({ cmd: "is_dev_tools_opened", windowId });
    },
    /** DevTools 토글 — F12 단축키와 동일 동작 */
    toggleDevTools(windowId) {
        return coreCall({ cmd: "toggle_dev_tools", windowId });
    },
    /** 줌 레벨 변경. Electron 호환 — 0 = 100%, 1 = 120%, -1 = 1/1.2 (logarithmic) */
    setZoomLevel(windowId, level) {
        return coreCall({ cmd: "set_zoom_level", windowId, level });
    },
    getZoomLevel(windowId) {
        return coreCall({ cmd: "get_zoom_level", windowId });
    },
    /** 줌 factor 변경. 1.0 = 100%, 1.5 = 150% (linear). 내부적으로 level = log(factor)/log(1.2) 변환 */
    setZoomFactor(windowId, factor) {
        return coreCall({ cmd: "set_zoom_factor", windowId, factor });
    },
    getZoomFactor(windowId) {
        return coreCall({ cmd: "get_zoom_factor", windowId });
    },
    // Phase 4-E: 편집 — 모두 main frame에 위임. 응답은 ok만.
    undo(windowId) {
        return coreCall({ cmd: "undo", windowId });
    },
    redo(windowId) {
        return coreCall({ cmd: "redo", windowId });
    },
    cut(windowId) {
        return coreCall({ cmd: "cut", windowId });
    },
    copy(windowId) {
        return coreCall({ cmd: "copy", windowId });
    },
    paste(windowId) {
        return coreCall({ cmd: "paste", windowId });
    },
    selectAll(windowId) {
        return coreCall({ cmd: "select_all", windowId });
    },
    /** 페이지 텍스트 검색. 첫 호출은 findNext=false, 이후 같은 단어 다음 매치는 true.
     *  결과 보고는 cef_find_handler_t로 (현재 미노출 — 추후 이벤트). */
    findInPage(windowId, text, options) {
        return coreCall({
            cmd: "find_in_page",
            windowId,
            text,
            forward: options?.forward ?? true,
            matchCase: options?.matchCase ?? false,
            findNext: options?.findNext ?? false,
        });
    },
    stopFindInPage(windowId, clearSelection = false) {
        return coreCall({ cmd: "stop_find_in_page", windowId, clearSelection });
    },
    /** PDF로 인쇄. CEF는 콜백 기반 async라 두 단계 신호:
     *  1. 코어 IPC 응답 — 요청 접수만 (CEF에 큐잉됨, 파일 아직 X).
     *  2. `window:pdf-print-finished` 이벤트({path, success}) — 실 PDF 작성 완료.
     *  이 SDK는 listener를 path로 매칭해 Promise<{success}>로 단일화 — 사용자는
     *  await 한 번만. 반환된 success가 false면 PDF 작성 실패 (디스크 권한 등).
     *
     *  주의: 같은 path로 동시 인쇄 시 첫 번째 완료 이벤트가 둘 다 resolve. 보통
     *  사용자 시나리오에서 동시 호출 드물어 OK. */
    printToPDF(windowId, path) {
        return new Promise((resolve) => {
            const off = on("window:pdf-print-finished", (data) => {
                const d = data;
                if (d.path === path) {
                    off();
                    resolve({ success: d.success === true });
                }
            });
            coreCall({ cmd: "print_to_pdf", windowId, path });
        });
    },
    // ── Phase 17-A: WebContentsView ──
    // viewId는 windowId와 같은 풀이라 loadURL/executeJavaScript/openDevTools/setZoomFactor
    // 등 모든 webContents API에 viewId를 그대로 넘기면 동작.
    /** host 창 contentView 안에 새 view 합성 (Electron `WebContentsView`). 자동으로 host의
     *  view_children top에 추가됨 — 이후 addChildView로 z-order 변경 가능. bounds 미지정 시
     *  800x600 @ 0,0 (코어의 parseBoundsFromJson은 누락 키를 0으로 채워 SDK가 default 적용). */
    createView(opts) {
        return coreCall({
            cmd: "create_view",
            hostId: opts.hostId,
            url: opts.url,
            name: opts.name,
            x: opts.bounds?.x ?? 0,
            y: opts.bounds?.y ?? 0,
            width: opts.bounds?.width ?? 800,
            height: opts.bounds?.height ?? 600,
        });
    },
    /** view 파괴. host의 view_children에서 자동 제거 + `window:view-destroyed` 이벤트 */
    destroyView(viewId) {
        return coreCall({ cmd: "destroy_view", viewId });
    },
    /** view를 host children에 추가/재배치. index 생략 시 top. 같은 view 재호출 시 위치 갱신
     *  (Electron WebContentsView idiom). host 이동은 미지원. */
    addChildView(hostId, viewId, index) {
        return coreCall({ cmd: "add_child_view", hostId, viewId, index });
    },
    /** view를 host children에서 분리 (destroy X). native에서 setHidden(true). 다시 addChildView
     *  로 같은 host에 붙일 수 있음. */
    removeChildView(hostId, viewId) {
        return coreCall({ cmd: "remove_child_view", hostId, viewId });
    },
    /** addChildView(host, view, undefined) 편의 — Electron `setTopBrowserView` 동등 */
    setTopView(hostId, viewId) {
        return coreCall({ cmd: "set_top_view", hostId, viewId });
    },
    /** view 위치/크기 변경. host contentView 좌표계 (top-left). */
    setViewBounds(viewId, bounds) {
        return coreCall({ cmd: "set_view_bounds", viewId, ...bounds });
    },
    /** view 표시/숨김 토글. CEF host.was_hidden도 함께 호출 (렌더링/입력 일시정지) */
    setViewVisible(viewId, visible) {
        return coreCall({ cmd: "set_view_visible", viewId, visible });
    },
    /** host의 child view id들을 z-order 순서로 조회 (0=bottom, 마지막=top) */
    getChildViews(hostId) {
        return coreCall({ cmd: "get_child_views", hostId });
    },
};
// ============================================
// clipboard — 시스템 클립보드 (Electron `clipboard.readText/writeText`)
// ============================================
// 현재 macOS만 지원 (NSPasteboard). Linux/Windows는 graceful no-op (read는 빈 문자열).
export const clipboard = {
    /** 클립보드의 plain text 읽기. 비어 있거나 non-text면 빈 문자열. */
    async readText() {
        const r = await coreCall({ cmd: "clipboard_read_text" });
        return r.text ?? "";
    },
    /** 클립보드에 plain text 쓰기. 성공 시 true. */
    async writeText(text) {
        const r = await coreCall({ cmd: "clipboard_write_text", text });
        return r.success === true;
    },
    /** 클립보드 비우기. */
    async clear() {
        const r = await coreCall({ cmd: "clipboard_clear" });
        return r.success === true;
    },
};
export const notification = {
    /** 플랫폼 지원 여부 — 현재 macOS만 true. */
    async isSupported() {
        const r = await coreCall({ cmd: "notification_is_supported" });
        return r.supported === true;
    },
    /** 알림 권한 요청 — 첫 호출 시 OS 다이얼로그. 이후 캐시. */
    async requestPermission() {
        const r = await coreCall({ cmd: "notification_request_permission" });
        return r.granted === true;
    },
    /** 알림 표시. 반환 `notificationId`로 close 가능. success=false면 권한/번들 문제. */
    async show(options) {
        return coreCall({
            cmd: "notification_show",
            ...options,
        });
    },
    async close(notificationId) {
        const r = await coreCall({ cmd: "notification_close", notificationId });
        return r.success === true;
    },
};
export const tray = {
    /** 새 시스템 트레이 아이콘 생성. 반환된 trayId로 이후 update/destroy. */
    async create(options = {}) {
        return coreCall({ cmd: "tray_create", ...options });
    },
    async setTitle(trayId, title) {
        const r = await coreCall({ cmd: "tray_set_title", trayId, title });
        return r.success === true;
    },
    async setTooltip(trayId, tooltip) {
        const r = await coreCall({ cmd: "tray_set_tooltip", trayId, tooltip });
        return r.success === true;
    },
    /** 트레이 클릭 시 표시될 컨텍스트 메뉴 설정. items는 분리선/일반 항목 혼합 가능.
     *  메뉴 항목 클릭은 `suji.on('tray:menu-click', ({trayId, click}) => ...)` 로 수신. */
    async setMenu(trayId, items) {
        const r = await coreCall({ cmd: "tray_set_menu", trayId, items });
        return r.success === true;
    },
    async destroy(trayId) {
        const r = await coreCall({ cmd: "tray_destroy", trayId });
        return r.success === true;
    },
};
export const menu = {
    async setApplicationMenu(items) {
        const r = await coreCall({ cmd: "menu_set_application_menu", items });
        return r.success === true;
    },
    async resetApplicationMenu() {
        const r = await coreCall({ cmd: "menu_reset_application_menu" });
        return r.success === true;
    },
};
// ============================================
// globalShortcut — macOS Carbon Hot Key (Electron `globalShortcut.*`)
// ============================================
// Accelerator syntax: "Cmd+Shift+K", "CommandOrControl+P", "Alt+F4". Trigger fires on
// `globalShortcut:trigger {accelerator, click}` via `suji.on`. Linux/Windows are stubs.
export const globalShortcut = {
    async register(accelerator, click) {
        const r = await coreCall({ cmd: "global_shortcut_register", accelerator, click });
        return r.success === true;
    },
    async unregister(accelerator) {
        const r = await coreCall({ cmd: "global_shortcut_unregister", accelerator });
        return r.success === true;
    },
    async unregisterAll() {
        const r = await coreCall({ cmd: "global_shortcut_unregister_all" });
        return r.success === true;
    },
    async isRegistered(accelerator) {
        const r = await coreCall({ cmd: "global_shortcut_is_registered", accelerator });
        return r.registered === true;
    },
};
// ============================================
// shell — 외부 핸들러 호출 (Electron `shell.*`)
// ============================================
// 현재 macOS만 지원 (NSWorkspace + NSBeep). Linux/Windows는 항상 false.
export const shell = {
    /** URL을 시스템 기본 핸들러로 열기 (http(s) → 브라우저, mailto: → 메일 앱 등).
     *  잘못된 URL syntax면 false. */
    async openExternal(url) {
        const r = await coreCall({ cmd: "shell_open_external", url });
        return r.success === true;
    },
    /** Finder/탐색기에서 파일/폴더 reveal — 부모 폴더 열리고 항목 선택. 경로 없으면 false. */
    async showItemInFolder(path) {
        const r = await coreCall({ cmd: "shell_show_item_in_folder", path });
        return r.success === true;
    },
    /** 시스템 비프음. */
    async beep() {
        const r = await coreCall({ cmd: "shell_beep" });
        return r.success === true;
    },
    /** 휴지통으로 이동. macOS NSFileManager `trashItemAtURL:`. 실패하면 false. */
    async trashItem(path) {
        const r = await coreCall({ cmd: "shell_trash_item", path });
        return r.success === true;
    },
};
export const fs = {
    async readFile(path) {
        const r = await coreCall({ cmd: "fs_read_file", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_read_file failed");
        return r.text;
    },
    async writeFile(path, text) {
        const r = await coreCall({ cmd: "fs_write_file", path, text });
        return r.success === true;
    },
    async stat(path) {
        const r = await coreCall({ cmd: "fs_stat", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_stat failed");
        return r;
    },
    async mkdir(path, options = {}) {
        const r = await coreCall({ cmd: "fs_mkdir", path, recursive: options.recursive === true });
        return r.success === true;
    },
    async readdir(path) {
        const r = await coreCall({ cmd: "fs_readdir", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_readdir failed");
        return r.entries;
    },
    /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
    async rm(path, options = {}) {
        const r = await coreCall({
            cmd: "fs_rm",
            path,
            recursive: options.recursive === true,
            force: options.force === true,
        });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_rm failed");
        return true;
    },
};
/// Dialog 함수의 Electron 두-인자 오버로드 분해. 첫 인자가 number면 windowId(=sheet 부모),
/// 아니면 options 단일 인자로 free-floating modal.
function splitDialogArgs(arg1, arg2) {
    if (typeof arg1 === "number") {
        return { windowId: arg1, options: (arg2 ?? {}) };
    }
    return { options: arg1 };
}
export const dialog = {
    /** 메시지 박스. 첫 인자에 windowId(number) 주면 sheet — 그 창에 부착. 없으면 free-floating.
     *  반환: 사용자가 클릭한 버튼 index + checkbox 상태. */
    async showMessageBox(arg1, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_message_box",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    /** 단순 에러 popup (NSAlert critical style + OK 버튼). 응답 없음 — Electron 동등. */
    async showErrorBox(title, content) {
        await coreCall({ cmd: "dialog_show_error_box", title, content });
    },
    /** 파일/폴더 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePaths:[]}`. */
    async showOpenDialog(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_open_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    /** 저장 경로 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePath:""}`. */
    async showSaveDialog(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_save_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    // ── Sync 변종 — Electron 호환. modal 동안 부모 창 입력 차단되는 건 async와 동일.
    // JS 측 응답 shape만 다름: number / string[] | undefined / string | undefined.
    /** Sync 변종 — `response: number`만 반환. windowId 첫 인자 지원. */
    async showMessageBoxSync(arg1, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_message_box",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.response;
    },
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string[]`. windowId 첫 인자 지원. */
    async showOpenDialogSync(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_open_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.canceled ? undefined : r.filePaths;
    },
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string`. windowId 첫 인자 지원. */
    async showSaveDialogSync(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_save_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.canceled ? undefined : r.filePath;
    },
};
// ============================================
// webRequest — URL glob blocklist (Electron `session.webRequest`)
// ============================================
// declarative 패턴만 지원 — JS callback decision은 후속 (sync IPC deadlock 방지).
// 매칭 시 fetch/XHR/이미지 등 모든 요청 cancel. `*` wildcard만 지원.
//
// 이벤트 (suji.on(...)으로 listen):
//   `webRequest:before-request` — { url } (모든 요청, 자체 페이지 asset/HMR 포함 — 노이즈
//                                   많음. consumer가 prefix/regex로 필터 권장)
//   `webRequest:completed` — { url, statusCode, requestStatus, receivedBytes }
//                             requestStatus: 0=UNKNOWN 1=SUCCESS 2=IO_PENDING 3=CANCELED 4=FAILED.
//                             blocklist 매칭 차단 시 statusCode=0 + requestStatus=FAILED(4)
//                             — CEF가 handler-initiated cancel을 FAILED로 보고 (CANCELED는
//                             user-initiated만).
export const webRequest = {
    /** blocklist 패턴 list 갱신 (전체 교체). 빈 list = 모든 요청 통과. 최대 32개, 256자/패턴. */
    async setBlockedUrls(patterns) {
        const r = await coreCall({
            cmd: "web_request_set_blocked_urls",
            patterns,
        });
        return r.count;
    },
};
export const screen = {
    /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
    async getAllDisplays() {
        const r = await coreCall({ cmd: "screen_get_all_displays" });
        return r.displays;
    },
};
export const powerSaveBlocker = {
    /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
    async start(type) {
        const r = await coreCall({ cmd: "power_save_blocker_start", type });
        return r.id;
    },
    /** start로 받은 id를 해제. unknown id는 false. */
    async stop(id) {
        const r = await coreCall({ cmd: "power_save_blocker_stop", id });
        return r.success === true;
    },
};
// ============================================
// safeStorage — macOS Keychain 저장소 (Electron `safeStorage`의 키체인 변종)
// ============================================
// Electron API는 encryptString/decryptString 패턴이지만 Suji는 service+account
// 키체인 직접 wrap. macOS만 동작 (Linux libsecret / Win DPAPI는 후속).
export const safeStorage = {
    /** service+account에 utf-8 value 저장. 같은 키면 update (idempotent). */
    async setItem(service, account, value) {
        const r = await coreCall({
            cmd: "safe_storage_set",
            service,
            account,
            value,
        });
        return r.success === true;
    },
    /** service+account로 저장된 value read. 없으면 빈 문자열. */
    async getItem(service, account) {
        const r = await coreCall({
            cmd: "safe_storage_get",
            service,
            account,
        });
        return r.value;
    },
    /** service+account 삭제. 존재하지 않아도 true (idempotent). */
    async deleteItem(service, account) {
        const r = await coreCall({
            cmd: "safe_storage_delete",
            service,
            account,
        });
        return r.success === true;
    },
};
export const app = {
    /** Electron `app.getPath` 동등. 표준 디렉토리 경로 반환. unknown 키는 빈 문자열. */
    async getPath(name) {
        const r = await coreCall({ cmd: "app_get_path", name });
        return r.path;
    },
    /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
    async requestUserAttention(critical = true) {
        const r = await coreCall({ cmd: "app_attention_request", critical });
        return r.id;
    },
    /** requestUserAttention으로 받은 id 취소. id == 0은 false (guard). */
    async cancelUserAttentionRequest(id) {
        const r = await coreCall({ cmd: "app_attention_cancel", id });
        return r.success === true;
    },
    dock: {
        /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
        async setBadge(text) {
            await coreCall({ cmd: "dock_set_badge", text });
        },
        /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
        async getBadge() {
            const r = await coreCall({ cmd: "dock_get_badge" });
            return r.text;
        },
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
