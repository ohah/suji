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
#import <strings.h>

#define SUJI_HOTKEY_MAX 64
#define SUJI_HOTKEY_STR_MAX 128

typedef struct {
    EventHotKeyRef ref;
    UInt32 hkid;
    char accelerator[SUJI_HOTKEY_STR_MAX];
    char click[SUJI_HOTKEY_STR_MAX];
} HotKeyEntry;

static HotKeyEntry g_hotkeys[SUJI_HOTKEY_MAX];
static int g_hotkey_count = 0;
static UInt32 g_next_hkid = 1;
static EventHandlerRef g_event_handler = NULL;
static void (*g_callback)(const char *accelerator, const char *click) = NULL;

typedef struct {
    UInt32 modifiers;
    UInt32 virt_key;
    BOOL valid;
} ParsedAccel;

static UInt32 virt_key_for(const char *name) {
    if (name == NULL || *name == 0) return UINT32_MAX;

    // 단일 알파벳/숫자
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

    // 함수 키 F1~F20
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

int suji_global_shortcut_register(const char *accel, const char *click) {
    if (!accel || !*accel) return 0;
    if (g_hotkey_count >= SUJI_HOTKEY_MAX) return 0;
    if (find_index(accel) >= 0) return 0;

    ParsedAccel p = parse_accelerator(accel);
    if (!p.valid) return 0;

    EventHotKeyRef ref = NULL;
    EventHotKeyID hkid = { .signature = 'sjsk', .id = g_next_hkid++ };
    OSStatus s = RegisterEventHotKey(p.virt_key, p.modifiers, hkid, GetApplicationEventTarget(), 0, &ref);
    if (s != noErr || ref == NULL) return 0;

    HotKeyEntry *e = &g_hotkeys[g_hotkey_count++];
    e->ref = ref;
    e->hkid = hkid.id;
    strncpy(e->accelerator, accel, sizeof(e->accelerator) - 1);
    e->accelerator[sizeof(e->accelerator) - 1] = 0;
    if (click) {
        strncpy(e->click, click, sizeof(e->click) - 1);
        e->click[sizeof(e->click) - 1] = 0;
    } else {
        e->click[0] = 0;
    }
    ensure_event_handler();
    return 1;
}

int suji_global_shortcut_unregister(const char *accel) {
    int idx = find_index(accel);
    if (idx < 0) return 0;
    UnregisterEventHotKey(g_hotkeys[idx].ref);
    for (int j = idx; j < g_hotkey_count - 1; j++) {
        g_hotkeys[j] = g_hotkeys[j + 1];
    }
    g_hotkey_count--;
    return 1;
}

void suji_global_shortcut_unregister_all(void) {
    for (int i = 0; i < g_hotkey_count; i++) {
        UnregisterEventHotKey(g_hotkeys[i].ref);
    }
    g_hotkey_count = 0;
}

int suji_global_shortcut_is_registered(const char *accel) {
    return (find_index(accel) >= 0) ? 1 : 0;
}
