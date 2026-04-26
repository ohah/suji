// Package fs provides Suji file-system APIs through the core IPC channel.
package fs

import (
	"encoding/json"

	suji "github.com/ohah/suji-go"
)

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

func buildReadFileRequest(path string) string {
	return mustJSON(map[string]interface{}{
		"cmd":  "fs_read_file",
		"path": path,
	})
}

func buildWriteFileRequest(path, text string) string {
	return mustJSON(map[string]interface{}{
		"cmd":  "fs_write_file",
		"path": path,
		"text": text,
	})
}

func buildStatRequest(path string) string {
	return mustJSON(map[string]interface{}{
		"cmd":  "fs_stat",
		"path": path,
	})
}

func buildMkdirRequest(path string, recursive bool) string {
	return mustJSON(map[string]interface{}{
		"cmd":       "fs_mkdir",
		"path":      path,
		"recursive": recursive,
	})
}

func buildReadDirRequest(path string) string {
	return mustJSON(map[string]interface{}{
		"cmd":  "fs_readdir",
		"path": path,
	})
}

func mustJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}
