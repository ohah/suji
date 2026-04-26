// Package fs provides Suji file-system APIs through the core IPC channel.
package fs

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// FileType — fs.StatTyped / fs.ReadDirTyped 결과 타입.
type FileType string

const (
	TypeFile      FileType = "file"
	TypeDirectory FileType = "directory"
	TypeSymlink   FileType = "symlink"
	TypeOther     FileType = "other"
)

// FileStat — fs.StatTyped 결과 (raw `Stat()`와 fn 이름 충돌 회피).
// MtimeMs는 epoch ms (JS Date(mtime) 호환).
type FileStat struct {
	Type    FileType
	Size    uint64
	MtimeMs int64
}

// DirEntry — fs.ReadDirTyped 한 entry.
type DirEntry struct {
	Name string
	Type FileType
}

func parseFileType(s string) FileType {
	switch s {
	case "file":
		return TypeFile
	case "directory":
		return TypeDirectory
	case "symlink":
		return TypeSymlink
	default:
		return TypeOther
	}
}

func ReadFile(path string) string {
	return suji.Invoke("__core__", buildReadFileRequest(path))
}

func WriteFile(path, text string) string {
	return suji.Invoke("__core__", buildWriteFileRequest(path, text))
}

func Stat(path string) string {
	return suji.Invoke("__core__", buildStatRequest(path))
}

func Mkdir(path string, recursive bool) string {
	return suji.Invoke("__core__", buildMkdirRequest(path, recursive))
}

func ReadDir(path string) string {
	return suji.Invoke("__core__", buildReadDirRequest(path))
}

// Rm removes a path. recursive=true for directory tree, force=true to ignore not-found
// (Node fs.rm({recursive,force}) semantics).
func Rm(path string, recursive, force bool) string {
	return suji.Invoke("__core__", buildRmRequest(path, recursive, force))
}

// StatTyped — Stat의 typed wrapper. 실패 시 nil (path 거부 / not_found / sandbox forbidden).
func StatTyped(path string) *FileStat {
	raw := Stat(path)
	if raw == "" {
		return nil
	}
	var v struct {
		Success bool   `json:"success"`
		Type    string `json:"type"`
		Size    uint64 `json:"size"`
		Mtime   int64  `json:"mtime"`
	}
	if err := json.Unmarshal([]byte(raw), &v); err != nil || !v.Success {
		return nil
	}
	return &FileStat{
		Type:    parseFileType(v.Type),
		Size:    v.Size,
		MtimeMs: v.Mtime,
	}
}

// ReadDirTyped — ReadDir의 typed wrapper. 실패 시 nil.
func ReadDirTyped(path string) []DirEntry {
	raw := ReadDir(path)
	if raw == "" {
		return nil
	}
	var v struct {
		Success bool `json:"success"`
		Entries []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"entries"`
	}
	if err := json.Unmarshal([]byte(raw), &v); err != nil || !v.Success {
		return nil
	}
	out := make([]DirEntry, len(v.Entries))
	for i, e := range v.Entries {
		out[i] = DirEntry{Name: e.Name, Type: parseFileType(e.Type)}
	}
	return out
}

func buildReadFileRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_read_file","path":"%s"}`, jsonesc.Full(path))
}

func buildWriteFileRequest(path, text string) string {
	return fmt.Sprintf(`{"cmd":"fs_write_file","path":"%s","text":"%s"}`, jsonesc.Full(path), jsonesc.Full(text))
}

func buildStatRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_stat","path":"%s"}`, jsonesc.Full(path))
}

func buildMkdirRequest(path string, recursive bool) string {
	return fmt.Sprintf(`{"cmd":"fs_mkdir","path":"%s","recursive":%t}`, jsonesc.Full(path), recursive)
}

func buildReadDirRequest(path string) string {
	return fmt.Sprintf(`{"cmd":"fs_readdir","path":"%s"}`, jsonesc.Full(path))
}

func buildRmRequest(path string, recursive, force bool) string {
	return fmt.Sprintf(`{"cmd":"fs_rm","path":"%s","recursive":%t,"force":%t}`, jsonesc.Full(path), recursive, force)
}
