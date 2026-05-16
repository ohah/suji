// iOS 정적 링크 Go 백엔드 예제 (c-archive).
//
// 레포의 다른 Go 예제 관례대로 C ABI 를 인라인하되, iOS 단일 바이너리에서
// Rust(suji_rs_*)·Zig 코어와 충돌하지 않도록 고유 suji_go_* 심볼로 노출한다.
// sdks/suji-go SDK 도 동일 suji_go_* 진입점을 제공(모듈 사용 시).
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"
)

func handle(cmd string, req map[string]any) any {
	switch cmd {
	case "go:ping":
		return map[string]any{"pong": true, "from": "go-native-ios"}
	case "go:upper":
		s, _ := req["s"].(string)
		out := make([]byte, len(s))
		for i := 0; i < len(s); i++ {
			c := s[i]
			if c >= 'a' && c <= 'z' {
				c -= 32
			}
			out[i] = c
		}
		return map[string]any{"upper": string(out)}
	default:
		return map[string]any{"error": "unknown: " + cmd}
	}
}

//export suji_go_backend_init
func suji_go_backend_init(_ unsafe.Pointer) {}

//export suji_go_backend_handle_ipc
func suji_go_backend_handle_ipc(request *C.char) *C.char {
	var req map[string]any
	_ = json.Unmarshal([]byte(C.GoString(request)), &req)
	cmd, _ := req["cmd"].(string)
	resp, _ := json.Marshal(map[string]any{
		"from": "go", "cmd": cmd, "result": handle(cmd, req),
	})
	return C.CString(string(resp))
}

//export suji_go_backend_free
func suji_go_backend_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

//export suji_go_backend_destroy
func suji_go_backend_destroy() {}

func main() {}
