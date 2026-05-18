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
#include <stddef.h> /* size_t — suji_core_set_permissions */

#ifdef __cplusplus
extern "C" {
#endif

/* 코어 초기화. 0=성공, -1=실패(suji_core_last_error 로 사유). */
int suji_core_init(void);

/* 마지막으로 기록된 suji_core_* 실패 사유 (사람이 읽음). lifecycle 내에선
 * sticky — 성공 호출은 안 지우고 suji_core_init 성공만 리셋. 기록 없으면 "".
 * 정적 포인터 — free 금지, 다음 실패 전까지 유효. */
const char *suji_core_last_error(void);

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

/* 호스트 invoke 핸들러.
 * channel/json 은 널종단(코어 소유, 콜백 동안만 유효).
 * ⚠️ `channel` 인자는 *등록명이 아닐 수 있다*: 요청 json 에 "cmd" 필드가
 *    있으면 코어가 그 cmd 값을 channel 로 넘긴다(extractCmdField; 없으면
 *    등록명). 즉 `__core__` 처럼 cmd 를 멀티플렉싱하는 단일 채널을 등록하면
 *    콜백은 channel="clipboard_write_text" 등을 받는다. **호스트는 channel
 *    인자에 의존하지 말고 json 의 cmd 로 분기하라**(channel==등록명 가정은
 *    Android 호스트가 빠졌던 함정 — git 8a86c91).
 * 반환: 응답 JSON(널종단, 호스트 소유) 또는 NULL(미처리 → 백엔드로 폴백).
 */
typedef const char *(*suji_core_handler_cb)(const char *channel, const char *json);
/* 위 콜백이 반환한 포인터 해제(코어가 복사 후 호출). NULL 이면 호스트가 미관리. */
typedef void (*suji_core_handler_free_cb)(const char *ptr);

/* 채널을 네이티브로 응답하도록 등록. (라우팅은 등록명 정확 매치지만
 * 콜백에 넘어오는 channel 인자는 위 cb typedef 주석 참조 — cmd 일 수 있음.)
 * dlopen 백엔드 없는 모바일에서 invoke 를 의미있게 만든다.
 * 같은 채널 재등록은 에러가 아니라 덮어쓰기. 0=성공, -1=실패(미초기화/메모리).
 */
int suji_core_register_handler(const char *channel,
                               suji_core_handler_cb invoke_cb,
                               suji_core_handler_free_cb free_cb);

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

/* 권한 정책 JSON 설정(Tauri 패리티 — 모바일 호스트가 init 후 1회/변경 시).
 * 형식: {"shell":{"allowedPaths":[...],"allowedExternalUrls":[...]},
 *        "dialog":{"allowedPaths":[...]},"fs":{"allowedRoots":[...]}}
 * json_ptr: JSON 바이트(호스트 소유 — 코어가 복사하므로 호출 후 free 가능),
 * len: 바이트 수(널종단 제외). NULL/len=0 → 정책 해제(전체 opt-in 허용).
 * uniform opt-in: 정책/패밀리 키 부재 → 허용(비파괴), 키 존재 → enforce
 * ([]=deny-all / ["*"]=allow / 특정=제한). 반환: 0=성공, -1=parse 오류. */
int suji_core_set_permissions(const char *json_ptr, size_t len);

/* 리소스 접근 허용 여부 질의(호스트가 네이티브 액션 전 호출).
 * family: IPC cmd 명 — "shell_open_external"(value=url),
 *   "shell_open_path"/"shell_show_item_in_folder"/"shell_trash_item"(path),
 *   "dialog_show_open_dialog"/"dialog_show_save_dialog"(defaultPath),
 *   "fs_*"(path). value: 검사할 path 또는 url.
 * is_backend: 1=backend SDK 호출(전부 우회), 0=프론트/네이티브(enforce).
 * 반환: 1=허용, 0=거부. (정책/패밀리 미설정 시 1=허용 — opt-in.) */
int suji_core_permission_check(const char *family, const char *value, int is_backend);

#ifdef __cplusplus
}
#endif

#endif /* SUJI_CORE_H */
