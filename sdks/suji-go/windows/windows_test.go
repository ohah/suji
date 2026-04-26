package windows

import (
	"testing"

	"github.com/ohah/suji-go/internal/jsonesc"
)

func TestJsonescFull(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"quote and backslash", `a"b\c`, `a\"b\\c`},
		{"control chars escaped to \\uXXXX", "a\nb\tc", `a\nb\tc`},
		{"normal passthrough", "hello world!", "hello world!"},
		{"empty", "", ""},
		{"only quote", `"`, `\"`},
		{"only backslash", `\`, `\\`},
		{"unicode preserved", "한글 🌟", "한글 🌟"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := jsonesc.Full(c.in); got != c.want {
				t.Errorf("jsonesc.Full(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
