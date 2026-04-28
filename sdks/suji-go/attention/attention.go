// Package attention provides Suji app.requestUserAttention API (dock bounce).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package attention

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

// Request starts dock bounce. critical=true는 활성화까지 반복, false는 1회.
// Response: `{"id":N}` (0이면 앱이 active라 no-op).
func Request(critical bool) string {
	return suji.Invoke("__core__", buildRequestRequest(critical))
}

// Cancel cancels a previously-issued request id. Response: `{"success":bool}`.
func Cancel(id uint32) string {
	return suji.Invoke("__core__", buildCancelRequest(id))
}

func buildRequestRequest(critical bool) string {
	return fmt.Sprintf(`{"cmd":"app_attention_request","critical":%t}`, critical)
}

func buildCancelRequest(id uint32) string {
	return fmt.Sprintf(`{"cmd":"app_attention_cancel","id":%d}`, id)
}
