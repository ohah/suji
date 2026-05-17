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

func TestParseWindowID(t *testing.T) {
	cases := []struct {
		raw  string
		want uint32
		err  bool
	}{
		{`{"windowId":7}`, 7, false},
		{`{"from":"x","windowId":42,"ok":true}`, 42, false},
		{`{"no":1}`, 0, true},
		{`not json`, 0, true},
	}
	for _, c := range cases {
		got, err := parseWindowID(c.raw)
		if c.err {
			if err == nil {
				t.Errorf("parseWindowID(%q) expected error", c.raw)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("parseWindowID(%q) = %d,%v want %d", c.raw, got, err, c.want)
		}
	}
}

func TestFromID(t *testing.T) {
	w := FromID(5)
	if w.ID != 5 {
		t.Errorf("FromID(5).ID = %d, want 5", w.ID)
	}
}
