#include "_cgo_export.h"

// SujiCore 타입 재선언 (export.go의 CGo 블록과 동일)
typedef struct {
    const char* (*invoke)(const char* backend_name, const char* request);
    void (*free_fn)(const char* response);
    void (*emit)(const char* channel, const char* data);
    unsigned long long (*on)(const char* channel, void* cb, void* arg);
    void (*off)(unsigned long long id);
} SujiCoreBridge;

// goEventBridge를 EventBus의 on()에 등록하는 브릿지
unsigned long long suji_bridge_on(void* core_ptr, const char* channel, void* arg) {
    SujiCoreBridge* core = (SujiCoreBridge*)core_ptr;
    return core->on(channel, (void*)goEventBridge, arg);
}
