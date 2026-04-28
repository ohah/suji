// Package safestorage provides Suji safeStorage API (macOS Keychain wrapper).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package safestorage

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// SetItem stores utf-8 value at service+account. Idempotent.
// Response: `{"success":bool}`.
func SetItem(service, account, value string) string {
	return suji.Invoke("__core__", buildSetRequest(service, account, value))
}

// GetItem reads value. Response: `{"value":"..."}` (없으면 빈 문자열).
func GetItem(service, account string) string {
	return suji.Invoke("__core__", buildGetRequest(service, account))
}

// DeleteItem removes entry. 없는 키도 idempotent true.
func DeleteItem(service, account string) string {
	return suji.Invoke("__core__", buildDeleteRequest(service, account))
}

func buildSetRequest(service, account, value string) string {
	return fmt.Sprintf(
		`{"cmd":"safe_storage_set","service":"%s","account":"%s","value":"%s"}`,
		jsonesc.Full(service), jsonesc.Full(account), jsonesc.Full(value),
	)
}

func buildGetRequest(service, account string) string {
	return fmt.Sprintf(
		`{"cmd":"safe_storage_get","service":"%s","account":"%s"}`,
		jsonesc.Full(service), jsonesc.Full(account),
	)
}

func buildDeleteRequest(service, account string) string {
	return fmt.Sprintf(
		`{"cmd":"safe_storage_delete","service":"%s","account":"%s"}`,
		jsonesc.Full(service), jsonesc.Full(account),
	)
}
