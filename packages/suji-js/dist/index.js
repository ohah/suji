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
