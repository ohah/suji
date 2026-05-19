// src/platform/global_shortcut.m
//
// macOS global shortcut wrapper — Carbon RegisterEventHotKey 기반 (Electron과 동일).
// NSEvent.addGlobalMonitorForEvents는 accessibility 권한 다이얼로그가 필요하지만
// Carbon HotKey는 권한 불필요 + .app 번들 없이도 동작.
//
// Accelerator 문자열 → (modifierMask, virtualKeyCode) 파싱 → RegisterEventHotKey →
// Carbon 이벤트 핸들러가 hkid 매칭 → C 콜백으로 (accelerator, click) 전달.

#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <AppKit/AppKit.h>
#import <strings.h>

// 미디어 키 — Carbon RegisterEventHotKey 로는 불가(키보드 hotkey 아님,
// NSEventTypeSystemDefined subtype 8). Electron 과 동일하게 NSEvent
// system-defined 글로벌+로컬 모니터로 별도 처리하되, accelerator 토큰은
// Electron 명칭 그대로(`MediaPlayPause`/`MediaNextTrack`/`MediaPreviousTrack`/
// `MediaStop`) — globalShortcut.register 한 경로로 동작(신규 API 0).
// NX_KEYTYPE_* (Apple <IOKit/hidsystem/ev_keymap.h> 안정 상수, 하드코딩).
#define SUJI_NX_KEYTYPE_PLAY      16
#define SUJI_NX_KEYTYPE_NEXT      17
#define SUJI_NX_KEYTYPE_PREVIOUS  18
// MediaStop: macOS HW 표준 transport 키 부재 — 토큰은 Electron 패리티로
// 수용(등록 성공)하되 실 HW 이벤트 소스 없음(정직: 대부분 키보드서 미발화).
#define SUJI_NX_KEYTYPE_STOP      255

// accelerator 가 미디어 토큰이면 NX_KEYTYPE, 아니면 0.
static UInt32 media_key_for(const char *name) {
    if (name == NULL || *name == 0) return 0;
    if (strcasecmp(name, "MediaPlayPause") == 0) return SUJI_NX_KEYTYPE_PLAY;
    if (strcasecmp(name, "MediaNextTrack") == 0) return SUJI_NX_KEYTYPE_NEXT;
    if (strcasecmp(name, "MediaPreviousTrack") == 0) return SUJI_NX_KEYTYPE_PREVIOUS;
    if (strcasecmp(name, "MediaStop") == 0) return SUJI_NX_KEYTYPE_STOP;
    return 0;
}

#define SUJI_HOTKEY_MAX 64
#define SUJI_HOTKEY_STR_MAX 128

typedef struct {
    EventHotKeyRef ref;       // 미디어 엔트리는 NULL (Carbon 미등록)
    UInt32 hkid;
    UInt32 media_key;         // 0 = 일반 Carbon hotkey, 그 외 = NX_KEYTYPE_*
    char accelerator[SUJI_HOTKEY_STR_MAX];
    char click[SUJI_HOTKEY_STR_MAX];
} HotKeyEntry;

static HotKeyEntry g_hotkeys[SUJI_HOTKEY_MAX];
static int g_hotkey_count = 0;
static UInt32 g_next_hkid = 1;
static EventHandlerRef g_event_handler = NULL;
static void (*g_callback)(const char *accelerator, const char *click) = NULL;
static id g_media_global_monitor = nil;
static id g_media_local_monitor = nil;

typedef struct {
    UInt32 modifiers;
    UInt32 virt_key;
    BOOL valid;
} ParsedAccel;

static UInt32 virt_key_for(const char *name) {
    if (name == NULL || *name == 0) return UINT32_MAX;

    if (strlen(name) == 1) {
        char c = name[0];
        if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
        switch (c) {
            case 'A': return kVK_ANSI_A;
            case 'B': return kVK_ANSI_B;
            case 'C': return kVK_ANSI_C;
            case 'D': return kVK_ANSI_D;
            case 'E': return kVK_ANSI_E;
            case 'F': return kVK_ANSI_F;
            case 'G': return kVK_ANSI_G;
            case 'H': return kVK_ANSI_H;
            case 'I': return kVK_ANSI_I;
            case 'J': return kVK_ANSI_J;
            case 'K': return kVK_ANSI_K;
            case 'L': return kVK_ANSI_L;
            case 'M': return kVK_ANSI_M;
            case 'N': return kVK_ANSI_N;
            case 'O': return kVK_ANSI_O;
            case 'P': return kVK_ANSI_P;
            case 'Q': return kVK_ANSI_Q;
            case 'R': return kVK_ANSI_R;
            case 'S': return kVK_ANSI_S;
            case 'T': return kVK_ANSI_T;
            case 'U': return kVK_ANSI_U;
            case 'V': return kVK_ANSI_V;
            case 'W': return kVK_ANSI_W;
            case 'X': return kVK_ANSI_X;
            case 'Y': return kVK_ANSI_Y;
            case 'Z': return kVK_ANSI_Z;
            case '0': return kVK_ANSI_0;
            case '1': return kVK_ANSI_1;
            case '2': return kVK_ANSI_2;
            case '3': return kVK_ANSI_3;
            case '4': return kVK_ANSI_4;
            case '5': return kVK_ANSI_5;
            case '6': return kVK_ANSI_6;
            case '7': return kVK_ANSI_7;
            case '8': return kVK_ANSI_8;
            case '9': return kVK_ANSI_9;
        }
    }

    if ((name[0] == 'F' || name[0] == 'f') && name[1] != 0) {
        int n = atoi(name + 1);
        switch (n) {
            case 1:  return kVK_F1;
            case 2:  return kVK_F2;
            case 3:  return kVK_F3;
            case 4:  return kVK_F4;
            case 5:  return kVK_F5;
            case 6:  return kVK_F6;
            case 7:  return kVK_F7;
            case 8:  return kVK_F8;
            case 9:  return kVK_F9;
            case 10: return kVK_F10;
            case 11: return kVK_F11;
            case 12: return kVK_F12;
            case 13: return kVK_F13;
            case 14: return kVK_F14;
            case 15: return kVK_F15;
            case 16: return kVK_F16;
            case 17: return kVK_F17;
            case 18: return kVK_F18;
            case 19: return kVK_F19;
            case 20: return kVK_F20;
        }
    }

    if (strcasecmp(name, "Space") == 0) return kVK_Space;
    if (strcasecmp(name, "Tab") == 0) return kVK_Tab;
    if (strcasecmp(name, "Return") == 0 || strcasecmp(name, "Enter") == 0) return kVK_Return;
    if (strcasecmp(name, "Esc") == 0 || strcasecmp(name, "Escape") == 0) return kVK_Escape;
    if (strcasecmp(name, "Delete") == 0 || strcasecmp(name, "Backspace") == 0) return kVK_Delete;
    if (strcasecmp(name, "ForwardDelete") == 0) return kVK_ForwardDelete;
    if (strcasecmp(name, "Up") == 0) return kVK_UpArrow;
    if (strcasecmp(name, "Down") == 0) return kVK_DownArrow;
    if (strcasecmp(name, "Left") == 0) return kVK_LeftArrow;
    if (strcasecmp(name, "Right") == 0) return kVK_RightArrow;
    if (strcasecmp(name, "PageUp") == 0) return kVK_PageUp;
    if (strcasecmp(name, "PageDown") == 0) return kVK_PageDown;
    if (strcasecmp(name, "Home") == 0) return kVK_Home;
    if (strcasecmp(name, "End") == 0) return kVK_End;
    if (strcasecmp(name, "Plus") == 0) return kVK_ANSI_Equal;
    if (strcasecmp(name, "Minus") == 0) return kVK_ANSI_Minus;
    if (strcasecmp(name, "Comma") == 0) return kVK_ANSI_Comma;
    if (strcasecmp(name, "Period") == 0) return kVK_ANSI_Period;
    if (strcasecmp(name, "Slash") == 0) return kVK_ANSI_Slash;
    if (strcasecmp(name, "Backslash") == 0) return kVK_ANSI_Backslash;

    return UINT32_MAX;
}

static ParsedAccel parse_accelerator(const char *acc) {
    ParsedAccel out = {0};
    if (!acc || !*acc) return out;

    char buf[SUJI_HOTKEY_STR_MAX];
    strncpy(buf, acc, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;

    char *saveptr = NULL;
    char *tok = strtok_r(buf, "+", &saveptr);
    BOOL has_key = NO;
    while (tok) {
        while (*tok == ' ') tok++;
        char *end = tok + strlen(tok);
        while (end > tok && (*(end - 1) == ' ')) { end--; *end = 0; }
        if (*tok == 0) { tok = strtok_r(NULL, "+", &saveptr); continue; }

        if (strcasecmp(tok, "Cmd") == 0 || strcasecmp(tok, "Command") == 0 ||
            strcasecmp(tok, "CmdOrCtrl") == 0 || strcasecmp(tok, "CommandOrControl") == 0 ||
            strcasecmp(tok, "Meta") == 0 || strcasecmp(tok, "Super") == 0) {
            out.modifiers |= cmdKey;
        } else if (strcasecmp(tok, "Shift") == 0) {
            out.modifiers |= shiftKey;
        } else if (strcasecmp(tok, "Alt") == 0 || strcasecmp(tok, "Option") == 0) {
            out.modifiers |= optionKey;
        } else if (strcasecmp(tok, "Ctrl") == 0 || strcasecmp(tok, "Control") == 0) {
            out.modifiers |= controlKey;
        } else {
            // 두 번째 비-modifier 토큰은 거부 ("Cmd+A+B" → invalid).
            if (has_key) return (ParsedAccel){0};
            UInt32 vk = virt_key_for(tok);
            if (vk == UINT32_MAX) return out;
            out.virt_key = vk;
            has_key = YES;
        }
        tok = strtok_r(NULL, "+", &saveptr);
    }

    out.valid = has_key;
    return out;
}

static OSStatus hotkey_handler(EventHandlerCallRef next, EventRef event, void *data) {
    (void)next;
    (void)data;
    EventHotKeyID hkid;
    OSStatus s = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkid), NULL, &hkid);
    if (s != noErr) return noErr;
    for (int i = 0; i < g_hotkey_count; i++) {
        if (g_hotkeys[i].hkid == hkid.id) {
            if (g_callback) g_callback(g_hotkeys[i].accelerator, g_hotkeys[i].click);
            break;
        }
    }
    return noErr;
}

static void ensure_event_handler(void) {
    if (g_event_handler) return;
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetApplicationEventTarget(), hotkey_handler, 1, &spec, NULL, &g_event_handler);
}

// NSEventTypeSystemDefined media-key 디코드 → keyDown 시 등록된 media
// 엔트리로 g_callback (Carbon hotkey_handler 와 동일 emit 경로 재사용).
static void media_event_dispatch(NSEvent *event) {
    // type 은 NSEventMaskSystemDefined 모니터가 보장 — subtype 만 검사.
    if ([event subtype] != 8) return;
    int data1 = (int)[event data1];
    int key_code = (data1 & 0xFFFF0000) >> 16;
    int key_flags = data1 & 0x0000FFFF;
    int key_state = (key_flags & 0xFF00) >> 8;
    if (key_state != 0x0A) return; // 0x0A=down, 0x0B=up — down 만
    for (int i = 0; i < g_hotkey_count; i++) {
        if (g_hotkeys[i].media_key != 0 && (UInt32)key_code == g_hotkeys[i].media_key) {
            if (g_callback) g_callback(g_hotkeys[i].accelerator, g_hotkeys[i].click);
            break;
        }
    }
}

// 글로벌(앱 비포커스)+로컬(포커스) 모니터 1회 설치 — Electron 도 동일하게
// 양쪽. 프로세스 라이프타임 유지(ensure_event_handler 와 동일 정책).
// ⚠️ 글로벌 system-defined 키 수신은 Accessibility(TCC) 신뢰 필요 — 헤드리스
// /미부여 시 미발화(정직 경계: globalShortcut 실 키 e2e 불가와 동급).
// local 모니터를 sentinel 로 — global 은 TCC 미신뢰 시 nil 을 반환하므로
// dedup 기준으로 못 씀(매 register 마다 local 중복 설치/콜백 이중발화 유발).
// local 은 TCC 불요로 항상 non-nil → 안정 기준. global 은 nil 인 동안만 재시도.
static void ensure_media_monitor(void) {
    if (g_media_local_monitor) return;
    if (!g_media_global_monitor)
        g_media_global_monitor = [NSEvent
            addGlobalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                          handler:^(NSEvent *e) { media_event_dispatch(e); }];
    g_media_local_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                     handler:^NSEvent *(NSEvent *e) {
                                         media_event_dispatch(e);
                                         return e;
                                     }];
}

// 신규 슬롯 점유 + accelerator/click 안전 복사. capacity/dup 체크는 caller.
// hkid 는 명시 인자 — Carbon 경로는 RegisterEventHotKey 성공 후에만 ID 를
// 소비하므로 g_next_hkid 증가 정책을 caller 가 소유.
static HotKeyEntry *push_entry(EventHotKeyRef ref, UInt32 media_key, UInt32 hkid,
                               const char *accel, const char *click) {
    HotKeyEntry *e = &g_hotkeys[g_hotkey_count++];
    e->ref = ref;
    e->hkid = hkid;
    e->media_key = media_key;
    strncpy(e->accelerator, accel, sizeof(e->accelerator) - 1);
    e->accelerator[sizeof(e->accelerator) - 1] = 0;
    if (click) {
        strncpy(e->click, click, sizeof(e->click) - 1);
        e->click[sizeof(e->click) - 1] = 0;
    } else {
        e->click[0] = 0;
    }
    return e;
}

static int find_index(const char *accel) {
    for (int i = 0; i < g_hotkey_count; i++) {
        if (strcmp(g_hotkeys[i].accelerator, accel) == 0) return i;
    }
    return -1;
}

void suji_global_shortcut_set_callback(void (*cb)(const char *, const char *)) {
    g_callback = cb;
    ensure_event_handler();
}

// register status — main.zig가 caller 진단용 에러 문자열로 매핑.
//   0  = success
//  -1  = capacity full
//  -2  = already registered (동일 accelerator)
//  -3  = parse failure (빈 문자열 / invalid key / 다중 비-modifier 토큰)
//  -4  = OS reject (RegisterEventHotKey 실패)
//  -5  = accelerator string > SUJI_HOTKEY_STR_MAX (silent truncation 차단)
int suji_global_shortcut_register(const char *accel, const char *click) {
    if (!accel || !*accel) return -3;
    if (strlen(accel) >= SUJI_HOTKEY_STR_MAX) return -5;
    if (click && strlen(click) >= SUJI_HOTKEY_STR_MAX) return -5;
    if (g_hotkey_count >= SUJI_HOTKEY_MAX) return -1;
    if (find_index(accel) >= 0) return -2;

    // 미디어 키 분기 — Carbon 미사용. NSEvent system-defined 모니터로 처리
    // (Electron 패리티: 토큰만으로 등록, 수정자 없음). ref=NULL sentinel.
    UInt32 mk = media_key_for(accel);
    if (mk != 0) {
        push_entry(NULL, mk, g_next_hkid++, accel, click);
        ensure_media_monitor();
        return 0;
    }

    ParsedAccel p = parse_accelerator(accel);
    if (!p.valid) return -3;

    EventHotKeyRef ref = NULL;
    EventHotKeyID hkid = { .signature = 'sjsk', .id = g_next_hkid };
    OSStatus s = RegisterEventHotKey(p.virt_key, p.modifiers, hkid, GetApplicationEventTarget(), 0, &ref);
    if (s != noErr || ref == NULL) return -4;
    g_next_hkid++;

    push_entry(ref, 0, hkid.id, accel, click);
    return 0;
}

int suji_global_shortcut_unregister(const char *accel) {
    int idx = find_index(accel);
    if (idx < 0) return 0;
    if (g_hotkeys[idx].ref) UnregisterEventHotKey(g_hotkeys[idx].ref); // 미디어=NULL skip
    for (int j = idx; j < g_hotkey_count - 1; j++) {
        g_hotkeys[j] = g_hotkeys[j + 1];
    }
    g_hotkey_count--;
    return 1;
}

void suji_global_shortcut_unregister_all(void) {
    for (int i = 0; i < g_hotkey_count; i++) {
        if (g_hotkeys[i].ref) UnregisterEventHotKey(g_hotkeys[i].ref); // 미디어=NULL skip
    }
    g_hotkey_count = 0;
}

int suji_global_shortcut_is_registered(const char *accel) {
    return (find_index(accel) >= 0) ? 1 : 0;
}
