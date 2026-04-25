package windows

import "testing"

func TestEscapeJSON(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"quote and backslash", `a"b\c`, `a\"b\\c`},
		{"control chars dropped", "a\nb\tc", "abc"},
		{"normal passthrough", "hello world!", "hello world!"},
		{"empty", "", ""},
		{"only quote", `"`, `\"`},
		{"only backslash", `\`, `\\`},
		{"unicode preserved", "한글 🌟", "한글 🌟"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := escapeJSON(c.in); got != c.want {
				t.Errorf("escapeJSON(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
