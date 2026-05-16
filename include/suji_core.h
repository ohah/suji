/* suji_core — CEF 무관 임베드 코어 C ABI.
 *
 * `zig build lib [-Dtarget=<triple>]` 가 만드는 libsuji_core.a 의 export 표면.
 * 호스트(iOS Swift / Android JNI / 임의 네이티브 셸)가 include 하고 정적 링크.
 *
 * 구현: src/embed.zig. 이 헤더는 수기 동기화 대상 — export 추가 시 함께 갱신.
 *
 * 수명주기: suji_core_init() 1회 → invoke/emit/on … → suji_core_destroy().
 * 스레드: 단일 스레드 호스트 가정(독립 std.Io.Threaded single-threaded).
 */
#ifndef SUJI_CORE_H
#define SUJI_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 코어 초기화. 0=성공, -1=이미 초기화됨 또는 실패. */
int suji_core_init(void);

/* 코어 해제. init 전/후 idempotent(미초기화면 no-op). */
void suji_core_destroy(void);

/* 프론트엔드 invoke 디스패치.
 * channel: 라우팅 채널명. json: 요청 JSON(널종단).
 * 반환: 응답 JSON(널종단, 코어 소유). 사용 후 반드시 suji_core_free 로 해제.
 *       미초기화 시 빈 문자열("").
 */
const char *suji_core_invoke(const char *channel, const char *json);

/* suji_core_invoke 반환 포인터 해제. NULL/미초기화는 no-op. */
void suji_core_free(const char *ptr);

/* 이벤트 발행(전 창 브로드캐스트). */
void suji_core_emit(const char *event_name, const char *json);

/* 특정 창(WindowManager id)에만 이벤트 발행. */
void suji_core_emit_to(uint32_t target, const char *event_name, const char *json);

/* 이벤트 콜백 — event_name/data 는 널종단, arg 는 suji_core_on 에 넘긴 값. */
typedef void (*suji_core_event_cb)(const char *event_name,
                                   const char *data,
                                   void *arg);

/* 이벤트 구독. 반환: 리스너 id(0=실패/미초기화). */
uint64_t suji_core_on(const char *event_name, suji_core_event_cb callback, void *arg);

/* 리스너 해제. */
void suji_core_off(uint64_t listener_id);

#ifdef __cplusplus
}
#endif

#endif /* SUJI_CORE_H */
