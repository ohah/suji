package suji

/*
#include <stdlib.h>

typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
    void (*emit)(const char* channel, const char* data);
    unsigned long long (*on)(const char* channel, void* cb, void* arg);
    void (*off)(unsigned long long id);
    void (*reg)(const char* channel);
    // Zig plugin 전용. Go plugin은 sync/os 표준 패키지 사용 권장.
    const void* (*get_io)(void);
    // 앱 종료 요청 (Electron app.quit() 호환).
    void (*quit)(void);
    // 플랫폼 이름 — "macos" | "linux" | "windows" | "other".
    const char* (*platform)(void);
} SujiCore;

static void core_register(SujiCore* core, const char* channel) {
    core->reg(channel);
}

static const char* core_invoke(SujiCore* core, const char* name, const char* req) {
    return core->invoke(name, req);
}

static void core_emit(SujiCore* core, const char* channel, const char* data) {
    core->emit(channel, data);
}

static void core_quit(SujiCore* core) {
    core->quit();
}

static const char* core_platform(SujiCore* core) {
    return core->platform();
}

// bridge.c에 정의된 함수 선언
extern unsigned long long suji_bridge_on(void* core_ptr, const char* channel, void* arg);
*/
import "C"

import (
	"fmt"
	"os"
	"sync"
	"unsafe"
)

var core *C.SujiCore

func Invoke(backend, request string) string {
	if core == nil {
		return `{"error":"core not initialized"}`
	}
	cName := C.CString(backend)
	defer C.free(unsafe.Pointer(cName))
	cReq := C.CString(request)
	defer C.free(unsafe.Pointer(cReq))
	resp := C.core_invoke(core, cName, cReq)
	if resp == nil {
		return "{}"
	}
	return C.GoString(resp)
}

// On registers an event listener connected to EventBus.
func On(channel string, callback func(channel, data string)) uint64 {
	if core == nil {
		return 0
	}

	goListenerMu.Lock()
	id := goListenerNextID
	goListenerNextID++
	goListeners[id] = callback
	goListenerMu.Unlock()

	// bridge.c → suji_bridge_on → core.on(channel, goEventBridge, id)
	cCh := C.CString(channel)
	defer C.free(unsafe.Pointer(cCh))
	C.suji_bridge_on(unsafe.Pointer(core), cCh, unsafe.Pointer(uintptr(id)))

	return id
}

func Off(id uint64) {
	goListenerMu.Lock()
	delete(goListeners, id)
	goListenerMu.Unlock()
}

var (
	goListeners      = make(map[uint64]func(string, string))
	goListenerNextID uint64 = 1
	goListenerMu     sync.RWMutex
)

func Send(channel, data string) {
	if core == nil {
		return
	}
	cCh := C.CString(channel)
	defer C.free(unsafe.Pointer(cCh))
	cData := C.CString(data)
	defer C.free(unsafe.Pointer(cData))
	C.core_emit(core, cCh, cData)
}

// Quit — 앱 종료 요청 (Electron app.quit() 호환).
// 주로 On("window:all-closed", ...) 핸들러에서 플랫폼 확인 후 호출.
// core 주입 전이면 silent no-op.
func Quit() {
	if core == nil {
		return
	}
	C.core_quit(core)
}

// Platform — 플랫폼 이름 ("macos" | "linux" | "windows" | "other").
// Electron process.platform 대응 (단 Suji는 "darwin" 대신 "macos").
func Platform() string {
	if core == nil {
		return "unknown"
	}
	ptr := C.core_platform(core)
	if ptr == nil {
		return "unknown"
	}
	return C.GoString(ptr)
}

// 플랫폼 상수 — Platform() 반환값과 비교할 때 사용.
// Suji는 macOS/Linux/Windows만 지원.
const (
	PlatformMacOS   = "macos"
	PlatformLinux   = "linux"
	PlatformWindows = "windows"
)

//export backend_init
func backend_init(c *C.SujiCore) {
	core = c
	// 핸들러 채널 등록
	mu.RLock()
	for name := range handlers {
		cName := C.CString(name)
		C.core_register(c, cName)
		C.free(unsafe.Pointer(cName))
	}
	mu.RUnlock()
	fmt.Fprintf(os.Stderr, "[Go] ready\n")
}

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
	return C.CString(HandleIPC(C.GoString(request)))
}

//export backend_free
func backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export backend_destroy
func backend_destroy() {
	goListenerMu.Lock()
	goListeners = make(map[uint64]func(string, string))
	goListenerMu.Unlock()
	fmt.Fprintf(os.Stderr, "[Go] bye\n")
}
