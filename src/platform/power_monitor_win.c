// Windows powerMonitor event bridge.
//
// A message-only window receives:
//   - WM_POWERBROADCAST/PBT_APMSUSPEND -> suspend
//   - WM_POWERBROADCAST/PBT_APMRESUMEAUTOMATIC or PBT_APMRESUMESUSPEND -> resume
//   - WM_POWERBROADCAST/PBT_APMPOWERSTATUSCHANGE -> on-battery / on-ac (GetSystemPowerStatus)
//   - WM_WTSSESSION_CHANGE/WTS_SESSION_LOCK -> lock-screen
//   - WM_WTSSESSION_CHANGE/WTS_SESSION_UNLOCK -> unlock-screen
//
// shutdown 이벤트(macOS power:shutdown 패리티)는 message-only window 가
// WM_QUERYENDSESSION/WM_ENDSESSION broadcast 를 수신하지 못해(top-level window 필요)
// 정직 경계로 미지원 — 기존 power monitor 의 message-only 설계를 깨지 않기 위함.

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wtsapi32.h>

typedef void (*suji_power_cb)(const char *event);

static suji_power_cb g_callback = NULL;
static HANDLE g_thread = NULL;
static DWORD g_thread_id = 0;
static HANDLE g_ready_event = NULL;
static HWND g_hwnd = NULL;

static void emit_event(const char *event) {
    suji_power_cb cb = g_callback;
    if (cb) cb(event);
}

static LRESULT CALLBACK suji_power_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    (void)lparam;
    switch (msg) {
        case WM_POWERBROADCAST:
            if (wparam == PBT_APMSUSPEND) {
                emit_event("suspend");
                return TRUE;
            }
            if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
                emit_event("resume");
                return TRUE;
            }
            if (wparam == PBT_APMPOWERSTATUSCHANGE) {
                SYSTEM_POWER_STATUS sps;
                if (GetSystemPowerStatus(&sps)) {
                    // ACLineStatus: 0=offline(배터리), 1=online(AC), 255=unknown.
                    if (sps.ACLineStatus == 0) emit_event("on-battery");
                    else if (sps.ACLineStatus == 1) emit_event("on-ac");
                }
                return TRUE;
            }
            break;
        case WM_WTSSESSION_CHANGE:
            if (wparam == WTS_SESSION_LOCK) {
                emit_event("lock-screen");
                return 0;
            }
            if (wparam == WTS_SESSION_UNLOCK) {
                emit_event("unlock-screen");
                return 0;
            }
            break;
        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static DWORD WINAPI suji_power_thread_main(LPVOID unused) {
    (void)unused;
    g_thread_id = GetCurrentThreadId();

    const wchar_t class_name[] = L"SujiPowerMonitorMessageWindow";
    WNDCLASSW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.lpfnWndProc = suji_power_wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = class_name;
    RegisterClassW(&wc);

    g_hwnd = CreateWindowExW(
        0,
        class_name,
        L"",
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        NULL,
        wc.hInstance,
        NULL
    );

    if (g_hwnd) {
        WTSRegisterSessionNotification(g_hwnd, NOTIFY_FOR_THIS_SESSION);
    }
    if (g_ready_event) SetEvent(g_ready_event);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_hwnd) {
        WTSUnRegisterSessionNotification(g_hwnd);
        DestroyWindow(g_hwnd);
        g_hwnd = NULL;
    }
    g_thread_id = 0;
    return 0;
}

void suji_power_monitor_windows_install(void (*cb)(const char *event)) {
    g_callback = cb;
    if (g_thread) return;

    g_ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    g_thread = CreateThread(NULL, 0, suji_power_thread_main, NULL, 0, NULL);
    if (!g_thread) {
        if (g_ready_event) {
            CloseHandle(g_ready_event);
            g_ready_event = NULL;
        }
        return;
    }

    if (g_ready_event) {
        WaitForSingleObject(g_ready_event, 5000);
        CloseHandle(g_ready_event);
        g_ready_event = NULL;
    }
}

void suji_power_monitor_windows_uninstall(void) {
    g_callback = NULL;
    if (!g_thread) return;
    if (g_thread_id != 0) PostThreadMessageW(g_thread_id, WM_QUIT, 0, 0);
    WaitForSingleObject(g_thread, 5000);
    CloseHandle(g_thread);
    g_thread = NULL;
    g_thread_id = 0;
}

#endif
