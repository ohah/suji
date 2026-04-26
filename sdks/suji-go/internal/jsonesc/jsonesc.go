// Package jsonesc — JSON 문자열 리터럴 escape (suji-go 모듈 내부 공유 util).
// 외부 모듈에서 import 불가 (`internal/` 규칙).
package jsonesc

import (
	"fmt"
	"strings"
)

// Full — `\n`/`\t`/`\r`/`\b`/`\f`을 escape sequence로 보존, 그 외 control char(< 0x20)는
// `\u00XX`. 클립보드 / dialog 메시지처럼 줄바꿈/탭 의미가 있는 payload용.
//
// `windows.escapeJSON`(control char drop)과 의도적으로 다름 — 그쪽은 창 타이틀처럼
// 줄바꿈이 무의미한 케이스용.
func Full(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				b.WriteString(fmt.Sprintf(`\u%04x`, r))
			} else {
				b.WriteRune(r)
			}
		}
	}
	return b.String()
}
