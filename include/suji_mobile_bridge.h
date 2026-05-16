/* 모바일 호스트 공용 — (channel,json) → {"cmd":"<channel>", <json 본문>}.
 *
 * suji_core_register_handler 콜백은 (channel,json) 인데 백엔드의
 * *_backend_handle_ipc 는 `{"cmd":...}` 형태 요청을 받으므로 그 변환을 한 곳에
 * 둔다. tests/mobile-backends/verify.c 와 examples/android JNI 가 공유
 * (iOS 는 Swift라 Backends.swift 에 동형 구현).
 *
 * json 은 well-formed 단일객체(`{...}`) 가정 — 자체 닫는 `}` 가 결과를 닫는다.
 * 비-객체/공백시작은 empty 분기로 흘림. 반환: malloc 문자열(호출자가 free),
 * OOM 이면 NULL.
 */
#ifndef SUJI_MOBILE_BRIDGE_H
#define SUJI_MOBILE_BRIDGE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline char *suji_mobile_bridge(const char *channel, const char *json) {
    int empty = json == NULL || strcmp(json, "{}") == 0 || json[0] != '{';
    /* +32: 포맷 고정부(`{"cmd":"",`+NUL) 여유 (실사용은 strlen(json)-1). */
    size_t n = strlen(channel) + (json ? strlen(json) : 0) + 32;
    char *buf = (char *)malloc(n);
    if (!buf) return NULL;
    if (empty)
        snprintf(buf, n, "{\"cmd\":\"%s\"}", channel);
    else
        snprintf(buf, n, "{\"cmd\":\"%s\",%s", channel, json + 1); /* json+1: skip '{' */
    return buf;
}

#endif /* SUJI_MOBILE_BRIDGE_H */
