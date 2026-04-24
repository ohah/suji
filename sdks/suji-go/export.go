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
