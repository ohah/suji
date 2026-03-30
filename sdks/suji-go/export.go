package suji

/*
#include <stdlib.h>

typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
    void (*emit)(const char* channel, const char* data);
    unsigned long long (*on)(const char* channel, void* cb, void* arg);
    void (*off)(unsigned long long id);
} SujiCore;

static const char* core_invoke(SujiCore* core, const char* name, const char* req) {
    return core->invoke(name, req);
}

static void core_emit(SujiCore* core, const char* channel, const char* data) {
    core->emit(channel, data);
}
*/
import "C"

import (
	"fmt"
	"os"
	"sync"
	"unsafe"
)

var core *C.SujiCore

// Invoke calls another backend through the Zig core.
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

// On registers an event listener. Returns listener ID for Off().
func On(channel string, callback func(channel, data string)) uint64 {
	if core == nil {
		return 0
	}
	cCh := C.CString(channel)
	defer C.free(unsafe.Pointer(cCh))

	// Go 콜백을 글로벌 맵에 저장하고 C 콜백으로 래핑
	goListenerMu.Lock()
	id := goListenerNextID
	goListenerNextID++
	goListeners[id] = callback
	goListenerMu.Unlock()

	// NOTE: Go closures를 C 함수 포인터로 변환 불가 (CGo 제약)
	// 현재는 로컬 맵에만 저장. EventBus 연결은 미구현.
	// 이벤트 수신이 필요하면 handle()로 폴링하거나 향후 CGo 래퍼 구현 필요.
	return id
}

// Off removes an event listener by ID.
func Off(id uint64) {
	goListenerMu.Lock()
	delete(goListeners, id)
	goListenerMu.Unlock()
}

var (
	goListeners      = make(map[uint64]func(string, string))
	goListenerNextID uint64 = 1
	goListenerMu     sync.Mutex
)

// Send emits an event to the frontend and other backends.
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
