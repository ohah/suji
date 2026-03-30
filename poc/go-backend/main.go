package main

/*
#include <stdlib.h>

// SujiCore — Zig 코어가 백엔드에게 제공하는 API
typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
} SujiCore;

// 헬퍼: Go에서 C 함수 포인터 호출
static const char* core_invoke(SujiCore* core, const char* name, const char* req) {
    return core->invoke(name, req);
}
*/
import "C"

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

var (
	callCount   uint64
	core        *C.SujiCore
	sharedState struct {
		mu      sync.RWMutex
		entries []string
	}
)

type Request struct {
	Cmd       string `json:"cmd"`
	Data      string `json:"data,omitempty"`
	Size      int    `json:"size,omitempty"`
	GoRequest string `json:"go_request,omitempty"`
}

// 다른 백엔드 호출 헬퍼
func callBackend(name, request string) string {
	if core == nil {
		return `{"error":"core not initialized"}`
	}
	cName := C.CString(name)
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
	sharedState.entries = make([]string, 0)
	fmt.Fprintf(os.Stderr, "[Go] initialized (GOMAXPROCS=%d, core API connected)\n", runtime.GOMAXPROCS(0))
}

//export backend_handle_ipc
func backend_handle_ipc(request *C.char) *C.char {
	reqStr := C.GoString(request)
	count := atomic.AddUint64(&callCount, 1)

	var req Request
	var reqMap map[string]interface{}
	if err := json.Unmarshal([]byte(reqStr), &req); err != nil {
		req.Cmd = reqStr
	}
	json.Unmarshal([]byte(reqStr), &reqMap)

	var result string

	switch req.Cmd {
	case "ping":
		result = fmt.Sprintf(`{"from":"go","msg":"pong","count":%d}`, count)

	case "async_work":
		ch := make(chan string, 3)
		go func() { time.Sleep(5 * time.Millisecond); ch <- "task1" }()
		go func() { time.Sleep(3 * time.Millisecond); ch <- "task2" }()
		go func() { time.Sleep(1 * time.Millisecond); ch <- "task3" }()
		tasks := make([]string, 3)
		for i := 0; i < 3; i++ {
			tasks[i] = <-ch
		}
		result = fmt.Sprintf(`{"from":"go","tasks":["%s","%s","%s"],"count":%d}`, tasks[0], tasks[1], tasks[2], count)

	case "state_write":
		sharedState.mu.Lock()
		sharedState.entries = append(sharedState.entries, fmt.Sprintf("entry_%d", count))
		l := len(sharedState.entries)
		sharedState.mu.Unlock()
		result = fmt.Sprintf(`{"from":"go","action":"write","state_len":%d,"count":%d}`, l, count)

	case "state_read":
		sharedState.mu.RLock()
		l := len(sharedState.entries)
		last := ""
		if l > 0 {
			last = sharedState.entries[l-1]
		}
		sharedState.mu.RUnlock()
		result = fmt.Sprintf(`{"from":"go","action":"read","state_len":%d,"last":"%s"}`, l, last)

	case "cpu_heavy":
		data := req.Data
		if data == "" {
			data = "default"
		}
		hash := []byte(data)
		for i := 0; i < 1000; i++ {
			h := sha256.Sum256(hash)
			hash = h[:]
		}
		result = fmt.Sprintf(`{"from":"go","hash_len":%d,"count":%d}`, len(fmt.Sprintf("%x", hash)), count)

	case "gen_data":
		size := req.Size
		if size == 0 {
			size = 1024
		}
		data := strings.Repeat("X", size)
		result = fmt.Sprintf(`{"from":"go","data_len":%d,"count":%d}`, len(data), count)

	case "transform":
		data := req.Data
		if data == "" {
			if raw, ok := reqMap["data"]; ok {
				data = fmt.Sprintf("%v", raw)
			}
		}
		result = fmt.Sprintf(`{"from":"go","cmd":"transform","original":"%s","result":"%s","count":%d}`,
			data, strings.ToLower(data), count)

	case "stats_for_rust":
		data := ""
		if raw, ok := reqMap["data"]; ok {
			data = fmt.Sprintf("%v", raw)
		}
		wordCount := len(strings.Fields(data))
		charCount := len(data)
		result = fmt.Sprintf(`{"from":"go","cmd":"stats_for_rust","words":%d,"chars":%d,"count":%d}`,
			wordCount, charCount, count)

	case "process_and_relay":
		msg := ""
		if raw, ok := reqMap["msg"]; ok {
			msg = fmt.Sprintf("%v", raw)
		}
		processed := fmt.Sprintf("[go processed: %s]", msg)
		result = fmt.Sprintf(`{"from":"go","cmd":"process_and_relay","processed":"%s","count":%d}`,
			processed, count)

	// Go에서 Rust 호출 (크로스 백엔드)
	case "call_rust":
		rustReq := `{"cmd":"ping"}`
		if raw, ok := reqMap["rust_request"]; ok {
			rustReq = fmt.Sprintf("%v", raw)
		}
		rustResp := callBackend("rust", rustReq)
		result = fmt.Sprintf(`{"from":"go","cmd":"call_rust","rust_response":%s,"count":%d}`, rustResp, count)

	// Go goroutine + Rust tokio 협업
	case "collab":
		data := req.Data
		if data == "" {
			data = "hello world"
		}

		// 1. Go에서 goroutine으로 단어 세기
		var wg sync.WaitGroup
		var wordCount, charCount int
		wg.Add(1)
		go func() {
			defer wg.Done()
			wordCount = len(strings.Fields(data))
			charCount = len(data)
		}()
		wg.Wait()

		// 2. Rust에 해싱 요청 (크로스 백엔드)
		rustReq := fmt.Sprintf(`{"cmd":"cpu_heavy","data":"%s"}`, data)
		rustResp := callBackend("rust", rustReq)

		result = fmt.Sprintf(`{"from":"go","cmd":"collab","go_words":%d,"go_chars":%d,"rust_hash":%s,"count":%d}`,
			wordCount, charCount, rustResp, count)

	case "goroutine_storm":
		var wg sync.WaitGroup
		var counter int64
		for i := 0; i < 100; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				atomic.AddInt64(&counter, 1)
				time.Sleep(1 * time.Millisecond)
			}()
		}
		wg.Wait()
		result = fmt.Sprintf(`{"from":"go","goroutines_completed":%d,"count":%d}`, counter, count)

	default:
		result = fmt.Sprintf(`{"from":"go","echo":"%s","count":%d}`, req.Cmd, count)
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
	count := atomic.LoadUint64(&callCount)
	fmt.Fprintf(os.Stderr, "[Go] destroyed (total calls: %d)\n", count)
}

func main() {}
