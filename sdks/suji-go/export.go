package suji

/*
#include <stdlib.h>

typedef struct {
	const char* (*invoke)(const char* backend_name, const char* request);
	void (*free_fn)(const char* response);
} SujiCore;

static const char* core_invoke(SujiCore* core, const char* name, const char* req) {
	return core->invoke(name, req);
}
*/
import "C"

import (
	"fmt"
	"os"
	"unsafe"
)

var core *C.SujiCore

// CallBackend calls another backend through the Zig core.
//
//	result := suji.CallBackend("rust", `{"cmd":"ping"}`)
func CallBackend(backend, request string) string {
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

//export backend_init
func backend_init(c *C.SujiCore) {
	core = c
	fmt.Fprintf(os.Stderr, "[Go] ready (suji SDK)\n")
}

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
	reqStr := C.GoString(request)
	response := HandleIPC(reqStr)
	return C.CString(response)
}

//export backend_free
func backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export backend_destroy
func backend_destroy() {
	fmt.Fprintf(os.Stderr, "[Go] bye (suji SDK)\n")
}
