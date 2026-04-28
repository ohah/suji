// Package attention provides Suji app.requestUserAttention API (dock bounce).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package attention

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

// RequestUser starts dock bounce. critical=true는 활성화까지 반복, false는 1회.
// Response: `{"id":N}` (0이면 앱이 active라 no-op).
//
// 다른 SDK의 `requestUserAttention` / `request_user_attention`과 1:1 매핑되도록
// 명명 — package prefix `attention.RequestUser` 형태.
func RequestUser(critical bool) string {
	return suji.Invoke("__core__", buildRequestJSON(critical))
}

// CancelUserRequest cancels a previously-issued request id. Response: `{"success":bool}`.
func CancelUserRequest(id uint32) string {
	return suji.Invoke("__core__", buildCancelJSON(id))
}

func buildRequestJSON(critical bool) string {
	return fmt.Sprintf(`{"cmd":"app_attention_request","critical":%t}`, critical)
}

func buildCancelJSON(id uint32) string {
	return fmt.Sprintf(`{"cmd":"app_attention_cancel","id":%d}`, id)
}
