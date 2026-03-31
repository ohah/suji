package main

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
	fmt.Fprintf(os.Stderr, "[Go] ready\n")
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

//export backend_free
func backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export backend_destroy
func backend_destroy() { fmt.Fprintf(os.Stderr, "[Go] bye\n") }

func main() {}
