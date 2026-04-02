// Suji Node.js Bridge — C API for embedding Node.js
#ifndef SUJI_NODE_BRIDGE_H
#define SUJI_NODE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Node 런타임 초기화 (프로세스당 한 번)
int suji_node_init(int argc, char** argv);

// JS 파일 실행 + 이벤트 루프 (블로킹)
int suji_node_run(const char* entry_path);

// JS 파일 실행 + 이벤트 루프 (별도 스레드, 비블로킹)
int suji_node_run_async(const char* entry_path);

// 이벤트 루프 중지
void suji_node_stop(void);

// 전체 정리 (V8 + 플랫폼 해제)
void suji_node_shutdown(void);

// IPC: JS 함수 호출 (호출자가 suji_node_free로 해제)
const char* suji_node_invoke(const char* channel, const char* data);

// 응답 메모리 해제
void suji_node_free(const char* ptr);

// 콜백: JS에서 suji.handle() 호출 시
typedef const char* (*suji_node_handler_fn)(const char* channel, const char* data);
void suji_node_set_handler(suji_node_handler_fn handler);

#ifdef __cplusplus
}
#endif

#endif
