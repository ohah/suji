package main

/*
#include <stdlib.h>

typedef struct {
    const char* (*request_json)(const char* request);
    void (*free_response)(const char* response);
} SujiWindowApi;

typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
    void (*emit)(const char* channel, const char* data);
    unsigned long long (*on)(const char* channel, void* cb, void* arg);
    void (*off)(unsigned long long id);
    void (*reg)(const char* channel);
    const void* (*get_io)(void);
    void (*quit)(void);
    const char* (*platform)(void);
    void (*emit_to)(unsigned int window_id, const char* channel, const char* data);
    const SujiWindowApi* (*get_window_api)(void);
} SujiCore;

static void core_register(SujiCore* core, const char* ch) {
    core->reg(ch);
}

static const char* core_invoke(SujiCore* core, const char* name, const char* req) {
    return core->invoke(name, req);
}

static void core_emit(SujiCore* core, const char* channel, const char* data) {
    core->emit(channel, data);
}

static void core_emit_to(SujiCore* core, unsigned int window_id, const char* channel, const char* data) {
    core->emit_to(window_id, channel, data);
}

static void core_quit(SujiCore* core) { core->quit(); }
static const char* core_platform(SujiCore* core) { return core->platform(); }

// window:all-closed 콜백 (goEventBridge 패턴 대신 단순 C 콜백).
// cgo가 `//export`에서 자동 생성하는 prototype은 const qualifier가 없으므로
// 수동 extern도 non-const로 맞춰야 "conflicting types"로 빌드 실패하지 않는다.
extern void go_on_window_all_closed(char* ch, char* data, void* arg);

static unsigned long long register_window_all_closed(SujiCore* core) {
    return core->on("window:all-closed", (void*)go_on_window_all_closed, (void*)0);
}
*/
import "C"

import (
	"fmt"
	"os"
	"strings"
	"unsafe"
)

var core *C.SujiCore

func callRust(request string) string {
	if core == nil {
		return "{}"
	}
	cName := C.CString("rust")
	defer C.free(unsafe.Pointer(cName))
	cReq := C.CString(request)
	defer C.free(unsafe.Pointer(cReq))
	resp := C.core_invoke(core, cName, cReq)
	if resp == nil {
		return "{}"
	}
	return C.GoString(resp)
}

//export backend_init
func backend_init(c *C.SujiCore) {
	core = c
	// 핸들러 채널 등록
	for _, name := range []string{"ping", "greet", "call_rust", "collab", "stats_for_rust", "emit_event", "go-stress", "go-whoami", "go-echo-to-sender"} {
		cName := C.CString(name)
		C.core_register(c, cName)
		C.free(unsafe.Pointer(cName))
	}
	// Electron 패턴: window:all-closed 리스너
	C.register_window_all_closed(c)
	fmt.Fprintf(os.Stderr, "[Go] ready\n")
}

//export go_on_window_all_closed
func go_on_window_all_closed(ch *C.char, data *C.char, arg unsafe.Pointer) {
	_ = ch
	_ = data
	_ = arg
	if core == nil {
		return
	}
	pPtr := C.core_platform(core)
	p := "unknown"
	if pPtr != nil {
		p = C.GoString(pPtr)
	}
	fmt.Fprintf(os.Stderr, "[Go] window-all-closed received (platform=%s)\n", p)
	if p != "macos" {
		fmt.Fprintln(os.Stderr, "[Go] non-macOS → quit()")
		C.core_quit(core)
	}
}

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
	reqStr := C.GoString(request)

	// 간단한 cmd 추출
	cmd := extractCmd(reqStr)

	var result string
	switch cmd {
	case "ping":
		result = `{"from":"go","msg":"pong"}`

	// Go에서 Rust 호출
	case "call_rust":
		rustResp := callRust(`{"cmd":"ping"}`)
		result = fmt.Sprintf(`{"from":"go","rust_said":%s}`, rustResp)

	// 협업: Go가 통계, Rust가 해싱
	case "collab":
		data := extractField(reqStr, "data")
		if data == "" {
			data = "hello"
		}
		words := len(strings.Fields(data))
		chars := len(data)

		rustResp := callRust(fmt.Sprintf(`{"cmd":"collab","data":"%s"}`, data))
		result = fmt.Sprintf(`{"from":"go","words":%d,"chars":%d,"rust_collab":%s}`, words, chars, rustResp)

	case "stats_for_rust":
		data := extractField(reqStr, "data")
		words := len(strings.Fields(data))
		chars := len(data)
		result = fmt.Sprintf(`{"from":"go","words":%d,"chars":%d}`, words, chars)

	case "go-stress":
		depth := extractIntField(reqStr, "depth")
		if depth <= 0 {
			result = `{"base":"go","remaining":0}`
		} else {
			nextReq := fmt.Sprintf(`{"cmd":"node-stress","depth":%d}`, depth-1)
			cName := C.CString("node")
			cReq := C.CString(nextReq)
			respPtr := C.core_invoke(core, cName, cReq)
			C.free(unsafe.Pointer(cName))
			C.free(unsafe.Pointer(cReq))
			child := "{}"
			if respPtr != nil {
				child = C.GoString(respPtr)
			}
			result = fmt.Sprintf(`{"at":"go","child":%s}`, child)
		}

	case "emit_event":
		msg := extractField(reqStr, "msg")
		if msg == "" {
			msg = "hello from go"
		}
		if core != nil {
			cCh := C.CString("go-event")
			defer C.free(unsafe.Pointer(cCh))
			cData := C.CString(fmt.Sprintf(`{"from":"go","msg":"%s"}`, msg))
			defer C.free(unsafe.Pointer(cData))
			C.core_emit(core, cCh, cData)
		}
		result = fmt.Sprintf(`{"from":"go","cmd":"emit_event","sent_to":"go-event"}`)

	// Phase 2.5: wire의 __window / __window_name 에서 sender 창 컨텍스트 파생.
	case "go-whoami":
		winID := extractIntField(reqStr, "__window")
		winName := extractField(reqStr, "__window_name")
		if winName == "" {
			result = fmt.Sprintf(`{"from":"go","window":{"id":%d,"name":null}}`, winID)
		} else {
			result = fmt.Sprintf(`{"from":"go","window":{"id":%d,"name":"%s"}}`, winID, winName)
		}

	// Phase 2.5: sendTo — sender 창에게만 이벤트 에코백.
	case "go-echo-to-sender":
		winID := extractIntField(reqStr, "__window")
		text := extractField(reqStr, "text")
		if text == "" {
			text = "hi"
		}
		if core != nil {
			cCh := C.CString("go-echo")
			defer C.free(unsafe.Pointer(cCh))
			payload := fmt.Sprintf(`{"from":"go","text":"%s"}`, text)
			cData := C.CString(payload)
			defer C.free(unsafe.Pointer(cData))
			C.core_emit_to(core, C.uint(winID), cCh, cData)
		}
		result = fmt.Sprintf(`{"from":"go","sent_to":%d}`, winID)

	default:
		result = fmt.Sprintf(`{"from":"go","echo":"%s"}`, cmd)
	}

	return C.CString(result)
}

func extractCmd(json string) string {
	i := strings.Index(json, `"cmd":"`)
	if i == -1 {
		return json
	}
	start := i + 7
	end := strings.Index(json[start:], `"`)
	if end == -1 {
		return json
	}
	return json[start : start+end]
}

func extractField(json, field string) string {
	key := fmt.Sprintf(`"%s":"`, field)
	i := strings.Index(json, key)
	if i == -1 {
		return ""
	}
	start := i + len(key)
	end := strings.Index(json[start:], `"`)
	if end == -1 {
		return ""
	}
	return json[start : start+end]
}

// 정수 필드 파싱 (단순 JSON 스캐너, 중첩 무시)
func extractIntField(json, field string) int {
	key := fmt.Sprintf(`"%s":`, field)
	i := strings.Index(json, key)
	if i == -1 {
		return 0
	}
	start := i + len(key)
	end := start
	for end < len(json) && (json[end] == '-' || (json[end] >= '0' && json[end] <= '9')) {
		end++
	}
	if end == start {
		return 0
	}
	n := 0
	negative := false
	s := start
	if json[s] == '-' {
		negative = true
		s++
	}
	for ; s < end; s++ {
		n = n*10 + int(json[s]-'0')
	}
	if negative {
		return -n
	}
	return n
}

//export backend_free
func backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export backend_destroy
func backend_destroy() { fmt.Fprintf(os.Stderr, "[Go] bye\n") }

func main() {}
