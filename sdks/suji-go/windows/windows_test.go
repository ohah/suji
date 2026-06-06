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

func TestCreateViewRequest(t *testing.T) {
	got := createViewRequest(CreateViewArgs{
		HostID: 7,
		Name:   `side"bar`,
		URL:    "https://example.com/a",
		Bounds: SetBoundsArgs{X: 10, Y: 20, Width: 300, Height: 400},
	})
	want := `{"cmd":"create_view","hostId":7,"name":"side\"bar","url":"https://example.com/a","x":10,"y":20,"width":300,"height":400}`
	if got != want {
		t.Errorf("createViewRequest() = %q, want %q", got, want)
	}
}

func TestAddChildViewRequest(t *testing.T) {
	if got := addChildViewRequest(1, 2); got != `{"cmd":"add_child_view","hostId":1,"viewId":2}` {
		t.Errorf("addChildViewRequest() without index = %q", got)
	}
	if got := addChildViewRequest(1, 2, 0); got != `{"cmd":"add_child_view","hostId":1,"viewId":2,"index":0}` {
		t.Errorf("addChildViewRequest() with index = %q", got)
	}
}

func TestViewOperationRequests(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"destroy", destroyViewRequest(2), `{"cmd":"destroy_view","viewId":2}`},
		{"remove child", removeChildViewRequest(1, 2), `{"cmd":"remove_child_view","hostId":1,"viewId":2}`},
		{"set top", setTopViewRequest(1, 2), `{"cmd":"set_top_view","hostId":1,"viewId":2}`},
		{
			"set bounds",
			setViewBoundsRequest(2, SetBoundsArgs{X: 1, Y: 2, Width: 3, Height: 4}),
			`{"cmd":"set_view_bounds","viewId":2,"x":1,"y":2,"width":3,"height":4}`,
		},
		{"set visible", setViewVisibleRequest(2, false), `{"cmd":"set_view_visible","viewId":2,"visible":false}`},
		{"get children", getChildViewsRequest(1), `{"cmd":"get_child_views","hostId":1}`},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.got != c.want {
				t.Errorf("%s request = %q, want %q", c.name, c.got, c.want)
			}
		})
	}
}

func TestWindowStateRequests(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"minimize", windowOpRequest("minimize", 3), `{"cmd":"minimize","windowId":3}`},
		{"is_visible", windowOpRequest("is_visible", 7), `{"cmd":"is_visible","windowId":7}`},
		{"get_bounds", windowOpRequest("get_bounds", 1), `{"cmd":"get_bounds","windowId":1}`},
		{"restore", windowOpRequest("restore_window", 2), `{"cmd":"restore_window","windowId":2}`},
		{"close", windowOpRequest("destroy_window", 2), `{"cmd":"destroy_window","windowId":2}`},
		{"show", setVisibleRequest(2, true), `{"cmd":"set_visible","windowId":2,"visible":true}`},
		{"hide", setVisibleRequest(2, false), `{"cmd":"set_visible","windowId":2,"visible":false}`},
		{"set_fullscreen", setFullscreenRequest(4, true), `{"cmd":"set_fullscreen","windowId":4,"flag":true}`},
		{"set_always_on_top", setAlwaysOnTopRequest(5, true), `{"cmd":"set_always_on_top","windowId":5,"onTop":true}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.got != c.want {
				t.Errorf("%s request = %q, want %q", c.name, c.got, c.want)
			}
		})
	}
}
