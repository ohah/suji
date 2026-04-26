package fs

import (
	"encoding/json"
	"testing"
)

func TestBuildFsRequests(t *testing.T) {
	cases := []struct {
		name string
		req  string
		cmd  string
	}{
		{"read", buildReadFileRequest("/tmp/a.txt"), "fs_read_file"},
		{"write", buildWriteFileRequest("/tmp/a.txt", "hello\nworld"), "fs_write_file"},
		{"stat", buildStatRequest("/tmp/a.txt"), "fs_stat"},
		{"mkdir", buildMkdirRequest("/tmp/dir", true), "fs_mkdir"},
		{"readdir", buildReadDirRequest("/tmp/dir"), "fs_readdir"},
		{"rm", buildRmRequest("/tmp/x", true, true), "fs_rm"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got map[string]any
			if err := json.Unmarshal([]byte(tc.req), &got); err != nil {
				t.Fatalf("request is not valid JSON: %v", err)
			}
			if got["cmd"] != tc.cmd {
				t.Fatalf("cmd = %v", got["cmd"])
			}
		})
	}
}

func TestParseFileType(t *testing.T) {
	cases := []struct {
		in   string
		want FileType
	}{
		{"file", TypeFile},
		{"directory", TypeDirectory},
		{"symlink", TypeSymlink},
		{"socket", TypeOther},
		{"unknown", TypeOther},
		{"", TypeOther},
	}
	for _, c := range cases {
		if got := parseFileType(c.in); got != c.want {
			t.Errorf("parseFileType(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestBuildFsRequestsEscapesStrings(t *testing.T) {
	req := buildWriteFileRequest(`/tmp/한글 "a".txt`, "line1\nline2\\tail")
	var got map[string]any
	if err := json.Unmarshal([]byte(req), &got); err != nil {
		t.Fatalf("request is not valid JSON: %v", err)
	}
	if got["path"] != `/tmp/한글 "a".txt` {
		t.Fatalf("path = %q", got["path"])
	}
	if got["text"] != "line1\nline2\\tail" {
		t.Fatalf("text = %q", got["text"])
	}
}
