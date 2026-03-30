package main

/*
#include <stdlib.h>

typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
} SujiCore;
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"unsafe"
)

//export backend_init
func backend_init(c *C.SujiCore) {
	fmt.Fprintf(os.Stderr, "[Go] ready\n")
}

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
	reqStr := C.GoString(request)
	var reqMap map[string]interface{}
	json.Unmarshal([]byte(reqStr), &reqMap)

	cmd, _ := reqMap["cmd"].(string)

	var result string
	switch cmd {
	case "ping":
		result = `{"from":"go","msg":"pong"}`
	case "greet":
		name, _ := reqMap["name"].(string)
		if name == "" {
			name = "world"
		}
		result = fmt.Sprintf(`{"from":"go","msg":"Hello, %s!"}`, name)
	case "upper":
		text, _ := reqMap["text"].(string)
		result = fmt.Sprintf(`{"from":"go","result":"%s"}`, strings.ToUpper(text))
	case "words":
		text, _ := reqMap["text"].(string)
		count := len(strings.Fields(text))
		result = fmt.Sprintf(`{"from":"go","count":%d}`, count)
	default:
		result = fmt.Sprintf(`{"from":"go","echo":"%s"}`, cmd)
	}

	return C.CString(result)
}

//export backend_free
func backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export backend_destroy
func backend_destroy() {
	fmt.Fprintf(os.Stderr, "[Go] bye\n")
}

func main() {}
